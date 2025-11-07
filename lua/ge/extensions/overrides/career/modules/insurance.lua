-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.dependencies = {'career_career', 'career_modules_payment', 'career_modules_playerAttributes'}

local plInsuranceDataFileName = "insurance"

local secondsSinceLastPay = 0 -- deprecated; kept for backward compat if referenced
local policyElapsedSeconds = {}
local bonusDecrease = 0.05
local policyEditTime = 600 -- have to wait between perks editing
local testDriveClaimPrice = {
    money = {
        amount = 500,
        canBeNegative = true
    }
}
local minimumPolicyScore = 0.5
local quickRepairExtraPrice = 1000

-- loaded data
local availablePerks = {} -- to avoid copy pasting data in policies.json, this table comprises perks niceName and descriptions
local availablePolicies = {} -- the default insurance data in game folder

local plHistory = {} -- claims, tickets ...
local plPoliciesData = {} -- the player's saved insurance policies data
local insuredInvVehs = {} -- inventoryVehId with insurance id {invVehId : policyId}
local policyTows = {} -- policyId with tow count {policyId : towCount}
local vehiclePerksOverrides = {} -- per-vehicle perk indices { [invId] = { [perkName] = index } }

-- to calculate distance driven
local vec3Zero = vec3(0, 0, 0)
local lastPos = vec3(0, 0, 0)

-- helpers
-- this table represents the most commonly accessed insurance data of the current vehicle the player is driving
local currApplicablePolicyId = "-1"
local function getCurrentVehicleInventoryId()
    local plVehId = be:getPlayerVehicleID(0)
    if plVehId and plVehId ~= -1 then
        return career_modules_inventory.getInventoryIdFromVehicleId(plVehId)
    end
end

local repairOptions = {
    repairNoInsurance = function(invVehInfo)
        local repairDetails = career_modules_valueCalculator.getRepairDetails(invVehInfo)
        if not repairDetails then
            log("W", "insurance", "Failed to get repair details for vehicle")
            return nil
        end
        return {
            repairTime = repairDetails.repairTime or 0,
            isPolicyRepair = false,
            repairName = translateLanguage("insurance.repairOptions.repairNoInsurance.name",
              "insurance.repairOptions.repairNoInsurance.name", true),
            priceOptions = {{ -- one choice
            {
                text = "",
                price = {
                    money = {
                        amount = repairDetails.price or 0,
                        canBeNegative = false
                    }
                }
            }}}
        }
    end,
    normalRepair = function(invVehInfo)
        local policyId = insuredInvVehs[tostring(invVehInfo.id)] or 0
        if policyId > 0 then
            local vehicleValueUndamaged = career_modules_valueCalculator.getInventoryVehicleValue(invVehInfo.id, true) or 0
            local vehicleValueDamaged = career_modules_valueCalculator.getInventoryVehicleValue(invVehInfo.id, false) or 0
            local valueLoss = vehicleValueUndamaged - vehicleValueDamaged
            local totalPct = M.getPlPerkValue(policyId, "totalPercentage") or 50
            local threshold = vehicleValueUndamaged * (totalPct / 100)
            if valueLoss >= threshold then
                return nil
            end
        end
        local perkRepairTime = M.getPlPerkValue(policyId, "repairTime") or math.huge
        local repairDetails = career_modules_valueCalculator.getRepairDetails(invVehInfo)
        if not repairDetails then
            log("W", "insurance", "Failed to get repair details for vehicle")
            return nil
        end
        return {
            repairTime = math.min(perkRepairTime, repairDetails.repairTime or 0),
            isPolicyRepair = true,
            repairName = translateLanguage("insurance.repairOptions.normalRepair.name",
              "insurance.repairOptions.normalRepair.name", true),
            priceOptions = {{ -- one choice
            {
                text = "",
                price = {
                    money = {
                        amount = M.getActualRepairPrice(invVehInfo),
                        canBeNegative = true
                    }
                }
            }}}
        }
    end,
    quickRepair = function(invVehInfo)
        local policyId = insuredInvVehs[tostring(invVehInfo.id)] or 0
        if M.getPlPerkValue(policyId, "quickRepair") ~= true then
            return nil
        end
        if policyId > 0 then
            local vehicleValueUndamaged = career_modules_valueCalculator.getInventoryVehicleValue(invVehInfo.id, true) or 0
            local vehicleValueDamaged = career_modules_valueCalculator.getInventoryVehicleValue(invVehInfo.id, false) or 0
            local valueLoss = vehicleValueUndamaged - vehicleValueDamaged
            local totalPct = M.getPlPerkValue(policyId, "totalPercentage") or 50
            local threshold = vehicleValueUndamaged * (totalPct / 100)
            if valueLoss >= threshold then
                return nil
            end
        end
        return {
            repairTime = 0,
            isPolicyRepair = true,
            repairName = translateLanguage("insurance.repairOptions.quickRepair.name",
              "insurance.repairOptions.quickRepair.name", true),
            priceOptions = {{{
                text = "",
                price = {
                    money = {
                        amount = M.getActualRepairPrice(invVehInfo),
                        canBeNegative = true
                    }
                }
            }, {
                text = "as extra fee",
                price = {
                    money = {
                        amount = quickRepairExtraPrice,
                        canBeNegative = true
                    }
                }
            }}, {{
                text = "",
                price = {
                    vouchers = {
                        amount = 1,
                        canBeNegative = false
                    }
                }
            }}}
        }
    end,
    insuranceTotalLoss = function(invVehInfo)
        local policyId = insuredInvVehs[tostring(invVehInfo.id)] or 0
        if policyId <= 0 then return nil end
        local vehicleValueUndamaged = career_modules_valueCalculator.getInventoryVehicleValue(invVehInfo.id, true) or 0
        local vehicleValueDamaged = career_modules_valueCalculator.getInventoryVehicleValue(invVehInfo.id, false) or 0
        local valueLoss = vehicleValueUndamaged - vehicleValueDamaged
        local totalPct = M.getPlPerkValue(policyId, "totalPercentage") or 50
        local threshold = vehicleValueUndamaged * (totalPct / 100)
        if valueLoss < threshold then return nil end
        return {
            repairTime = 0,
            isPolicyRepair = true,
            repairName = "Total Out Vehicle",
            priceOptions = {
                {
                    {
                        text = "Pay Out",
                        price = { money = { amount = vehicleValueUndamaged * -0.75, canBeNegative = false } }
                    }
                }
            }
        }
    end,
    instantFreeRepair = function(invVehInfo)
        return {
            hideInComputer = true,
            repairTime = 0,
            skipSound = true,
            paintRepair = true
        }
    end
}

local gestures = {
    freeRepair = function(data)
        local plPolicyData = data.plPolicyData
        if plPolicyData.hasFreeRepair then
            return
        end

        local everyGestures = plHistory.policyHistory[tostring(plPolicyData.id)].freeRepairs
        local lastGesture = everyGestures[#everyGestures]
        if plPolicyData.totalMetersDriven - math.max(data.distRef, lastGesture and lastGesture.happenedAt or 0) >
          availablePolicies[plPolicyData.id].gestures.freeRepair.distance then
            plPolicyData.hasFreeRepair = true

            table.insert(plHistory.policyHistory[tostring(plPolicyData.id)].freeRepairs, {
                happenedAt = plPolicyData.totalMetersDriven,
                time = os.time()
            })

            ui_message(string.format(
              "Insurance policy '%s' has given you a repair forgiveness due to not having submitted any claim for a while",
              availablePolicies[plPolicyData.id].name), 6, "Insurance", "info")
        end
    end
}

local function getPlPerkValue(policyId, perkName)
    -- Type checking: ensure policyId is a valid number
    if not policyId or type(policyId) ~= "number" or policyId < 0 then
        return nil -- negative, nil, or non-numeric means not owned/assigned
    end
    local policy = availablePolicies[policyId]
    local pl = plPoliciesData[tostring(policyId)]
    if not policy or not pl then return nil end
    if not policy.perks or not pl.perks then return nil end
    if not policy.perks[perkName] or not pl.perks[perkName] then return nil end
    local choices = policy.perks[perkName].changeability and policy.perks[perkName].changeability.changeParams and policy.perks[perkName].changeability.changeParams.choices
    if choices then
        return choices[pl.perks[perkName]]
    end
    return policy.perks[perkName].changeability and policy.perks[perkName].changeability.premiumInfluence or nil
end

-- per-vehicle perk: returns the overridden value for invId if present; otherwise policy-level value
local function getVehPerkValue(invId, perkName)
    if not invId or not perkName then
        log("W", "insurance", "Invalid parameters for getVehPerkValue")
        return nil
    end

    local assigned = insuredInvVehs[tostring(invId)]
    if not assigned or assigned < 0 then return nil end
    local policyId = math.abs(assigned)
    local overrides = vehiclePerksOverrides[tostring(invId)] or {}
    local policy = availablePolicies[policyId]
    if not policy or not policy.perks then return getPlPerkValue(policyId, perkName) end
    local perkDef = policy.perks[perkName]
    if not perkDef then return getPlPerkValue(policyId, perkName) end
    local choices = perkDef.changeability and perkDef.changeability.changeParams and perkDef.changeability.changeParams.choices
    local overrideIdx0 = overrides[perkName]
    local index
    if overrideIdx0 ~= nil then
        index = overrideIdx0 + 1
    else
        index = plPoliciesData[tostring(policyId)] and plPoliciesData[tostring(policyId)].perks and plPoliciesData[tostring(policyId)].perks[perkName]
    end
    if choices and index and choices[index] then
        return choices[index]
    end
    return getPlPerkValue(policyId, perkName)
end

local function normalizePolicyKeys(inputTable)
    if not inputTable or type(inputTable) ~= 'table' then
        return inputTable or {}
    end

    local normalizedTable = {}

    -- Convert all keys to strings and collect unique values
    local keyValueMap = {}
    for key, value in pairs(inputTable) do
        local stringKey = tostring(key)
        -- If we already have this key, keep the more recent value (string keys might be older)
        if not keyValueMap[stringKey] then
            keyValueMap[stringKey] = value
        end
    end

    -- Second pass: assign to normalized table with string keys
    for stringKey, value in pairs(keyValueMap) do
        normalizedTable[stringKey] = value
    end

    return normalizedTable
end

-- Normalize plHistory keys to ensure string keys for policyHistory
local function normalizePlHistoryKeys(inputHistory)
    if not inputHistory or type(inputHistory) ~= 'table' then
        return inputHistory or { generalHistory = { ticketEvents = {}, testDriveClaims = {} }, policyHistory = {} }
    end

    local normalizedHistory = {
        generalHistory = inputHistory.generalHistory or { ticketEvents = {}, testDriveClaims = {} },
        policyHistory = {}
    }

    -- Normalize policyHistory keys
    if inputHistory.policyHistory then
        for key, value in pairs(inputHistory.policyHistory) do
            normalizedHistory.policyHistory[tostring(key)] = value
        end
    end

    return normalizedHistory
end

local function savePoliciesData(currentSavePath)
    local dataToSave = {
        plPoliciesData = plPoliciesData,
        insuredInvVehs = insuredInvVehs,
        plHistory = plHistory,
        policyTows = policyTows or {},
        vehiclePerksOverrides = vehiclePerksOverrides or {},
        policyElapsedSeconds = policyElapsedSeconds or {}
    }

    career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/" .. plInsuranceDataFileName .. ".json", dataToSave,
      true)
end

local function initCurrInsurance()
    local newid = be:getPlayerVehicleID(0)
    if newid == -1 then
        return
    end

    if gameplay_walk.isWalking() then
        currApplicablePolicyId = "-1"
    else
        local invVehId = career_modules_inventory.getInventoryIdFromVehicleId(newid)
        if invVehId then
            local vehicles = career_modules_inventory.getVehicles()
            if not vehicles or not vehicles[invVehId] then
                log("W", "insurance", "Vehicle not found: " .. tostring(invVehId))
                currApplicablePolicyId = "-1"
                return
            end
            local owned = vehicles[invVehId].owned
            local hasPolicies = false
            for k, v in pairs(plPoliciesData) do
                hasPolicies = true
                break
            end
            if hasPolicies and owned then
                currApplicablePolicyId = tostring(insuredInvVehs[tostring(invVehId)] or 0)
                local plPolicyData = plPoliciesData[tostring(currApplicablePolicyId)]
                policyElapsedSeconds[tostring(currApplicablePolicyId)] = policyElapsedSeconds[tostring(currApplicablePolicyId)] or 0
                local newVeh = scenetree.findObjectById(newid)
                if newVeh then
                    lastPos:set(newVeh:getPosition())
                end
            else
                currApplicablePolicyId = "-1"
            end
        else
            currApplicablePolicyId = "-1"
        end
    end
end

local function loadPoliciesData(resetSomeData)
    if resetSomeData == nil then
        resetSomeData = false
    end

    local saveSlot, savePath = career_saveSystem.getCurrentSaveSlot()
    if not saveSlot then
        return
    end

    local policiesJsonData = jsonReadFile("gameplay/insurance/rlsPolicies.json")
    if not policiesJsonData then
        policiesJsonData = jsonReadFile("gameplay/insurance/policies.json")
    end
    -- Convert to id-keyed map so policy id 0 works and we can index by id
    availablePolicies = {}
    if policiesJsonData and policiesJsonData.insurancePolicies then
        for _, p in ipairs(policiesJsonData.insurancePolicies) do
            availablePolicies[p.id] = p
        end
    end
    availablePerks = policiesJsonData.perks

    -- in order to avoid copying/pasting the common properties of every perk in policies.json, we define them once in availablePerks and then add those fields to each perk
    for _, policyInfo in pairs(availablePolicies) do
        local t = translateLanguage(policyInfo.name, policyInfo.name, true)
        policyInfo.name = translateLanguage(policyInfo.name, policyInfo.name, true)
        policyInfo.description = translateLanguage(policyInfo.description, policyInfo.description, true)
        policyInfo.perkPriceScale = {}
        local renewal = policyInfo.perks.renewal
        if renewal.changeability and renewal.changeability.changeable and renewal.changeability.changeParams and renewal.changeability.changeParams.premiumInfluence then
            for index, price in pairs(renewal.changeability.changeParams.premiumInfluence) do
                local basePrice = renewal.changeability.changeParams.premiumInfluence[1] or 1
                if basePrice == 0 then
                    log("W", "insurance", "Division by zero prevented in perk price scale calculation, using fallback")
                    basePrice = 1 -- Prevent division by zero
                end
                table.insert(policyInfo.perkPriceScale, price / basePrice)
            end
        else
            policyInfo.perkPriceScale = {1}
        end
        for perkName, perkInfo in pairs(policyInfo.perks) do
            perkInfo.name = perkName
            perkInfo.unit = availablePerks[perkName].unit
            perkInfo.niceName = translateLanguage(availablePerks[perkName].niceName, availablePerks[perkName].niceName,
              true)
            perkInfo.desc = translateLanguage(availablePerks[perkName].desc, availablePerks[perkName].desc, true)
        end
    end

    local savedPlPolicyData =
      (savePath and jsonReadFile(savePath .. "/career/" .. plInsuranceDataFileName .. ".json")) or {}

    local isFirstLoadEver = not (savedPlPolicyData.plPoliciesData and next(savedPlPolicyData.plPoliciesData) ~= nil)
    if isFirstLoadEver then -- first load ever
        insuredInvVehs = {}
        plHistory = {
            generalHistory = {
                ticketEvents = {},
                testDriveClaims = {}
            },
            policyHistory = {}
        }
        plPoliciesData = {}
        policyTows = {}
        policyElapsedSeconds = {}
    else
        insuredInvVehs = savedPlPolicyData.insuredInvVehs or {}
        plHistory = savedPlPolicyData.plHistory or { generalHistory = { ticketEvents = {}, testDriveClaims = {} }, policyHistory = {} }
        plPoliciesData = savedPlPolicyData.plPoliciesData or {}
        vehiclePerksOverrides = savedPlPolicyData.vehiclePerksOverrides or {}
        policyElapsedSeconds = savedPlPolicyData.policyElapsedSeconds or {}
        for invId, assigned in pairs(insuredInvVehs) do
            if type(assigned) == 'number' and assigned < 0 then
                insuredInvVehs[tostring(invId)] = math.abs(assigned) or 0
            end
        end
        if not savedPlPolicyData.policyTows then
            for policyId, policyData in pairs(plPoliciesData) do
                local rsa = availablePolicies[policyId] and availablePolicies[policyId].perks and availablePolicies[policyId].perks["roadsideAssistance"]
                local towChoices = rsa and rsa.changeability and rsa.changeability.changeParams and rsa.changeability.changeParams.choices
                if towChoices and policyData and policyData.perks and policyData.perks.roadsideAssistance then
                    policyTows[policyId] = towChoices[policyData.perks.roadsideAssistance]
                else
                    policyTows[policyId] = 0
                end
            end
        else
            policyTows = savedPlPolicyData.policyTows
        end

        plPoliciesData = normalizePolicyKeys(plPoliciesData)
        policyTows = normalizePolicyKeys(policyTows)
        plHistory = normalizePlHistoryKeys(plHistory)
    end

    for invId, veh in pairs(career_modules_inventory.getVehicles() or {}) do
        local key = tostring(invId)
        if insuredInvVehs[key] == nil then
            insuredInvVehs[key] = 0
        end
    end

    for _, policyInfo in pairs(availablePolicies) do

        local updatedPerksData = {}
        for perkName, perkInfo in pairs(policyInfo.perks) do
            local currentIndex = plPoliciesData[tostring(policyInfo.id)] and plPoliciesData[tostring(policyInfo.id)].perks and plPoliciesData[tostring(policyInfo.id)].perks[perkName]
            local changeParams = perkInfo.changeability and perkInfo.changeability.changeParams
            local choices = changeParams and changeParams.choices
            if currentIndex == nil then
                updatedPerksData[perkName] = perkInfo.baseValue or 1
            else
                            if choices and #choices > 0 then
                updatedPerksData[perkName] = math.min(#choices - 1, math.max(0, currentIndex or 0))
            else
                updatedPerksData[perkName] = currentIndex or 1
            end
            end
        end

        if not plPoliciesData[tostring(policyInfo.id)] or resetSomeData then
            plPoliciesData[tostring(policyInfo.id)] = {
                id = policyInfo.id,
                nextPolicyEditTimer = 0,
                totalMetersDriven = 0,
                bonus = 1,
                hasFreeRepair = false,
                owned = false,
                policeStops = 0,
                policeFreeRepairAvailable = false
            }

            plHistory.policyHistory[tostring(policyInfo.id)] = {
                id = policyInfo.id,
                freeRepairs = {},
                claims = {},
                initialPurchase = {
                    purchaseTime = -1,
                    forFree = false
                },
                changedCoverage = {},
                renewedPolicy = {}
            }
        end
        plPoliciesData[tostring(policyInfo.id)].perks = updatedPerksData
        if not plPoliciesData[tostring(policyInfo.id)].policeStops then
            plPoliciesData[tostring(policyInfo.id)].policeStops = 0
        end
        if plPoliciesData[tostring(policyInfo.id)].policeFreeRepairAvailable == nil then
            plPoliciesData[tostring(policyInfo.id)].policeFreeRepairAvailable = false
        end
        if policyInfo.id == 0 then
            plPoliciesData[tostring(policyInfo.id)].owned = true -- No Insurance is always available
        end
        local rsa = availablePolicies[policyInfo.id].perks["roadsideAssistance"]
        local towChoices = rsa.changeability and rsa.changeability.changeParams and rsa.changeability.changeParams.choices
        if towChoices then
            policyTows[tostring(policyInfo.id)] = towChoices[plPoliciesData[tostring(policyInfo.id)].perks.roadsideAssistance]
        else
            policyTows[tostring(policyInfo.id)] = 0
        end
    end

    initCurrInsurance()
end

local function purchasePolicy(policyId, forFree)
    if forFree == nil then
        forFree = false
    end

    if not policyId or not availablePolicies[policyId] then
        log("W", "insurance", "Invalid policy ID provided to purchasePolicy: " .. tostring(policyId))
        return
    end

    local policyInfo = availablePolicies[policyId]
    local policyName = policyInfo.name or "Unknown Policy"
    local label = string.format("Bought insurance tier '%s'", policyName)

    if career_modules_payment.pay({
        money = {
            amount = forFree == true and 0 or policyInfo.initialBuyPrice,
            canBeNegative = false
        }
    }, {
        label = label
    }) then
        for invVehId, invVehPolicyId in pairs(insuredInvVehs) do
            if invVehPolicyId < 0 and math.abs(invVehPolicyId) == policyId then -- if not insured
                insuredInvVehs[tostring(invVehId)] = policyId
            end
        end

        if policyInfo.upgradedToFrom then
            for invVehId, invVehPolicyId in pairs(insuredInvVehs) do
                if invVehPolicyId == policyInfo.upgradedToFrom then
                    insuredInvVehs[tostring(invVehId)] = policyId
                end
            end
        end

        plPoliciesData[tostring(policyId)].owned = true
        plHistory.policyHistory[tostring(policyId)].initialPurchase = {
            purchaseTime = os.time(),
            forFree = forFree
        }
        M.sendUIData()
    end
end

local function inventoryVehNeedsRepair(vehInvId)
    if not vehInvId then
        log("W", "insurance", "Invalid vehicle ID provided to inventoryVehNeedsRepair")
        return false
    end

    local vehicles = career_modules_inventory.getVehicles()
    local vehInfo = vehicles and vehicles[vehInvId]

    if not vehInfo then
        log("W", "insurance", "Vehicle not found in inventory: " .. tostring(vehInvId))
        return false
    end

    if not vehInfo.partConditions then
        log("W", "insurance", "Vehicle has no part conditions: " .. tostring(vehInvId))
        return false
    end

    return career_modules_valueCalculator.partConditionsNeedRepair(vehInfo.partConditions) or false
end

local function repairPartConditions(data)
    if not data.partConditions then
        return
    end
    if data.paintRepair == nil then
        data.paintRepair = true
    end

    for partPath, info in pairs(data.partConditions) do
        if info.integrityValue then
            if info.integrityValue == 0 then

                local inventoryPart
                if data.inventoryId then
                    local map = career_modules_partInventory.getPartPathToPartIdMap()
                    if map and map[data.inventoryId] and map[data.inventoryId][partPath] then
                        local partId = map[data.inventoryId][partPath]
                        inventoryPart = career_modules_partInventory.getInventory()[partId]
                        inventoryPart.repairCount = inventoryPart.repairCount or 0
                        inventoryPart.repairCount = inventoryPart.repairCount + 1
                        local vehicle = career_modules_inventory.getVehicles()[data.inventoryId]
                        vehicle.changedSlots[inventoryPart.containingSlot] = true
                    end
                end

                -- reset the paint
                if info.visualState then
                    if info.visualState.paint and info.visualState.paint.originalPaints then
                        if data.paintRepair then
                            info.visualState = {
                                paint = {
                                    originalPaints = info.visualState.paint.originalPaints
                                }
                            }
                        else
                            local numberOfPaints = tableSize(info.visualState.paint.originalPaints)
                            info.visualState = {
                                paint = {
                                    originalPaints = {}
                                }
                            }
                            for index = 1, numberOfPaints do
                                info.visualState.paint.originalPaints[index] = career_modules_painting.getPrimerColor()
                            end

                            if inventoryPart then
                                inventoryPart.primered = true
                            end
                        end
                        info.visualState.paint.odometer = 0
                    else
                        -- if we dont have a replacement paint, just set visualState to nil
                        info.visualState = nil
                        info.visualValue = 1
                    end
                end
                info.odometer = 0
            end

            if info.integrityState and info.integrityState.energyStorage then
                -- keep the fuel level
                for _, tankData in pairs(info.integrityState.energyStorage) do
                    for attributeName, value in pairs(tankData) do
                        if attributeName ~= "storedEnergy" then
                            tankData[attributeName] = nil
                        end
                    end
                end
            else
                info.integrityState = nil
            end
            info.integrityValue = 1
        end
    end
end

-- when you damage a test drive vehicle, insurance needs to know
local function makeTestDriveDamageClaim(vehInfo)
    testDriveClaimPrice = {
        money = {
            amount = math.floor(vehInfo.value * 5) / 100,
            canBeNegative = true
        }
    }
    local label = string.format("Test drive vehicle damaged: -%i$", testDriveClaimPrice.money.amount)
    career_modules_payment.pay(testDriveClaimPrice, {
        label = label,
        tags = {"insurance", "repair", "testDrive"}
    })

    -- Calculate rate increase with division by zero protection
    local premiumDetails = M.calculatePremiumDetails(1)
    local repairTimePrice = 0
    if premiumDetails and premiumDetails.perksPriceDetails and premiumDetails.perksPriceDetails['repairTime'] then
        repairTimePrice = premiumDetails.perksPriceDetails['repairTime'].price or 0
    end

    -- Prevent division by zero
    local denominator = (700 - repairTimePrice) * 100
    if denominator == 0 then
        log("W", "insurance", "Division by zero prevented in test drive claim, using fallback value")
        denominator = 1 -- Fallback to prevent division by zero
    end

    local rateIncrease = 1 + math.floor(
        ((vehInfo.value * 0.05) / denominator) * 100) / 100

    -- Ensure rateIncrease is valid
    if not rateIncrease or rateIncrease ~= rateIncrease then -- Check for NaN
        rateIncrease = 1.0
        log("W", "insurance", "Invalid rateIncrease calculated, using default value")
    end

    local policyId = 1
    if (vehInfo.value > 80000) then
        policyId = 2
    end

    if plPoliciesData[tostring(policyId)] then
        local currentBonus = plPoliciesData[tostring(policyId)].bonus or 1.0
        plPoliciesData[tostring(policyId)].bonus = math.floor(currentBonus * rateIncrease * 100) / 100
    else
        log("W", "insurance", "Policy data not found for policy ID: " .. tostring(policyId))
    end

    label = label .. string.format("\nYour insurance went up to %0.2f", plPoliciesData[tostring(policyId)].bonus)
    ui_message(label, 5, "Insurance", "info")

    local claim = {
        time = os.time(),
        amount = math.floor(vehInfo.value * 5) / 100,
        policyScore = plPoliciesData[tostring(policyId)].bonus,
        reason = "Test drive vehicle damaged:\n" .. vehInfo.name,
        policyId = policyId
    }

    table.insert(plHistory.generalHistory.testDriveClaims, claim)
end

local function getPolicyIdFromInvVehId(invVehId)
    return insuredInvVehs[tostring(invVehId)] or 0
end

local function getPolicyScore(invVehId)
    local policyId = 1
    if invVehId then
        policyId = getPolicyIdFromInvVehId(invVehId)
    end
    if policyId == 0 or not plPoliciesData[tostring(policyId)] then
        -- Vehicle has no insurance or policy data not found
        return 1.0
    end
    return plPoliciesData[tostring(policyId)].bonus
end

local function changePolicyScore(invVehId, rate, operation)
    -- Enhanced type checking for all parameters
    if rate == nil or type(rate) ~= "number" or (rate ~= rate) then -- Check for NaN
        log("W", "insurance", "Invalid rate provided to changePolicyScore: " .. tostring(rate))
        return 1.0
    end

    if not operation then
        operation = function(bonus, rate)
            return bonus * rate
        end
    end

    local policyId
    if invVehId then
        policyId = getPolicyIdFromInvVehId(invVehId)
    end
    if not policyId or policyId == 0 then
        -- Vehicle has no insurance, no policy score to change
        return 1.0
    end

    if not plPoliciesData[tostring(policyId)] then
        log("W", "insurance", "Policy data not found for policy ID: " .. tostring(policyId))
        return 1.0
    end

    local currentBonus = plPoliciesData[tostring(policyId)].bonus or 1.0
    plPoliciesData[tostring(policyId)].bonus = math.min(math.max(operation(math.floor(currentBonus * 100) / 100, rate),
        minimumPolicyScore), 30)
    return plPoliciesData[tostring(policyId)].bonus
end

local function makeRepairClaim(invVehId, price, rateIncrease)
    if rateIncrease == nil then
        rateIncrease = 1 + bonusDecrease
    end
    local policyId = insuredInvVehs[tostring(invVehId)]
    local hasUsedFreeRepair = false

    -- Check for police free repair first (policy ID 4)
    if policyId == 4 and plPoliciesData[tostring(policyId)].policeFreeRepairAvailable then
        plPoliciesData[tostring(policyId)].policeFreeRepairAvailable = false
        hasUsedFreeRepair = true
        ui_message("Police insurance: Free repair used", 5, "Insurance", "info")
    elseif plPoliciesData[tostring(policyId)].hasFreeRepair then
        plPoliciesData[tostring(policyId)].hasFreeRepair = false
        hasUsedFreeRepair = true
    else
        local oldBonus = plPoliciesData[tostring(policyId)].bonus
        plPoliciesData[tostring(policyId)].bonus = math.min(math.floor(plPoliciesData[tostring(policyId)].bonus * rateIncrease * 100) / 100, 35)
        if rateIncrease ~= 1.0 and plPoliciesData[tostring(policyId)].bonus ~= oldBonus then
            local label = string.format("Your Insurance Score Increased by %.2fx to %.2f",
                                            rateIncrease, plPoliciesData[tostring(policyId)].bonus)
            ui_message(label, 5, "Insurance", "info")
        end
    end

    local claim = {
        deductible = price,
        policyScore = plPoliciesData[tostring(policyId)].bonus,
        freeRepair = hasUsedFreeRepair,
        vehInfo = {
            niceName = career_modules_inventory.getVehicles()[invVehId].niceName
        },
        happenedAt = plPoliciesData[tostring(policyId)].totalMetersDriven, -- to know when the claim happened, so can later on know how long the player hasn't made a claim for, and give him a bonus
        time = os.time()
    }

    career_modules_inventory.addAccident(invVehId)

    table.insert(plHistory.policyHistory[tostring(policyId)].claims, claim)
    extensions.hook("onInsuranceRepairClaim")
end

local function onAfterVehicleRepaired(vehInfo)
    career_modules_inventory.setVehicleDirty(vehInfo.id)
    local vehId = career_modules_inventory.getVehicleIdFromInventoryId(vehInfo.id)
    if vehId then
        career_modules_fuel.minimumRefuelingCheck(vehId)
        if gameplay_walk.isWalking() then
            local veh = getObjectByID(vehId)
            gameplay_walk.setRot(veh:getPosition() - getPlayerVehicle(0):getPosition())
        end
    end

    career_saveSystem.saveCurrent({vehInfo.id})
end

local startRepairVehInfo
local function startRepairDelayed(vehInfo, repairTime)
    if career_modules_inventory.getVehicleIdFromInventoryId(vehInfo.id) then -- vehicle is currently spawned
        if vehInfo.id == career_modules_inventory.getCurrentVehicle() then
            startRepairVehInfo = {
                inventoryId = vehInfo.id,
                repairTime = repairTime
            }
            gameplay_walk.setWalkingMode(true)
            return -- This function gets called again after the player left the vehicle
        end
        career_modules_inventory.removeVehicleObject(vehInfo.id)
    end
    career_modules_inventory.delayVehicleAccess(vehInfo.id, repairTime, "repair")
    onAfterVehicleRepaired(vehInfo)
end

local function missionStartRepairCallback(vehInfo)
    guihooks.trigger('MenuOpenModule', 'menu.careermission')
    guihooks.trigger('gameContextPlayerVehicleDamageInfo', {
        needsRepair = inventoryVehNeedsRepair(vehInfo.id)
    })
end

local function startRepairInstant(vehInfo, callback, skipSound)
    if not skipSound then
        Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Vehicle_Recover')
    end

    if career_modules_inventory.getVehicleIdFromInventoryId(vehInfo.id) then -- vehicle is currently spawned
        career_modules_inventory.spawnVehicle(vehInfo.id, 2, callback and function()
            callback(vehInfo)
            onAfterVehicleRepaired(vehInfo)
        end)
        if callback then
            return
        end
    end
    onAfterVehicleRepaired(vehInfo)
end

local function mergeRepairOptionPrices(price)
    local pricesList = {}

    if not price then
        return
    end

    for _, data in pairs(price) do
        table.insert(pricesList, data.price)
    end

    local merged = {}
    local canBeNegative
    for _, price in pairs(pricesList) do
        for currency, value in pairs(price) do
            if merged[currency] then
                merged[currency].amount = merged[currency].amount + value.amount
                merged[currency].canBeNegative = value.canBeNegative and merged[currency].canBeNegative
                canBeNegative = canBeNegative and value.canBeNegative
            else
                merged[currency] = {
                    amount = value.amount,
                    canBeNegative = value.canBeNegative
                }
                canBeNegative = value.canBeNegative
            end
        end
    end
    return merged, canBeNegative
end

local function getRateIncrease(vehId, fullcost, paid)
    local covering = math.max(fullcost - paid, 0)
    local details = M.calculatePremiumDetails(insuredInvVehs[tostring(vehId)] or 0)
    local repairPerk = details.perksPriceDetails and details.perksPriceDetails['repairTime'] or nil
    local repairPrice = (repairPerk and repairPerk.price) or 0

    -- Prevent division by zero
    local denominator = (700 - repairPrice) * 100
    if denominator == 0 then
        log("W", "insurance", "Division by zero prevented in getRateIncrease, using fallback value")
        denominator = 1 -- Fallback to prevent division by zero
    end

    return 1 + math.floor((covering / denominator) * 100) / 100
end

local function startRepair(inventoryId, repairOptionData, callback)
    career_modules_damageManager.clearDamageState(inventoryId)
    inventoryId = inventoryId or career_modules_inventory.getCurrentVehicle()
    if not inventoryId then
        log("W", "insurance", "No inventory ID provided to startRepair")
        return
    end

    repairOptionData = (repairOptionData and type(repairOptionData) == "table") and repairOptionData or {}
    repairOptionData.name = repairOptionData.name or "instantFreeRepair"

    local vehInfo = career_modules_inventory.getVehicles()[inventoryId]
    if not vehInfo then
        log("W", "insurance", "Vehicle not found in inventory: " .. tostring(inventoryId))
        return
    end

    local repairOption = repairOptions[repairOptionData.name] and repairOptions[repairOptionData.name](vehInfo) or nil
    if not repairOption then
        return
    end
    local price = mergeRepairOptionPrices(repairOption.priceOptions and
                                            repairOption.priceOptions[repairOptionData.priceOption or 1] or nil)

    if price and repairOptionData.name ~= "insuranceTotalLoss" then
        career_modules_payment.pay(price, {
            label = "Repaired a vehicle: " .. (vehInfo.niceName or "(Unnamed Vehicle)")
        })
        Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')
    end

    if repairOptionData.name == "insuranceTotalLoss" then
        -- Process total loss payout at 75% of current value and remove vehicle from inventory
        local payout = math.floor(career_modules_valueCalculator.getInventoryVehicleValue(inventoryId, true) * 0.75)
        career_modules_inventory.sellVehicle(inventoryId, payout)
        ui_message(string.format("Insurance total loss payout received: $%d", payout), 6, "Insurance", "info")
        return
    end

    if repairOption.isPolicyRepair then -- the player can repair on his own without insurance
        local increase = nil
        if price.money then
            increase = getRateIncrease(inventoryId, repairOptionData.fullCost or 0, price.money.amount)
        end
        makeRepairClaim(inventoryId, price, increase)
    end

    -- the actual repair
    local paintRepair = repairOption.paintRepair or getVehPerkValue(inventoryId, "paintRepair") == true
    local data = {
        partConditions = vehInfo.partConditions,
        paintRepair = paintRepair,
        inventoryId = inventoryId
    }
    repairPartConditions(data)

    -- no automatic totaling here; handled via explicit UI option

    M.closeMenu(true)
    if repairOption.repairTime > 0 then
        startRepairDelayed(vehInfo, repairOption.repairTime)
    else
        startRepairInstant(vehInfo, callback, repairOption.skipSound)
    end
    career_saveSystem.saveCurrent()
end

local function startRepairInGarage(vehInvInfo, repairOptionData)
    local repairOption = repairOptions[repairOptionData.name] and repairOptions[repairOptionData.name](vehInvInfo) or nil
    if not repairOption then
        return
    end

    local vehId = career_modules_inventory.getVehicleIdFromInventoryId(vehInvInfo.id)
    extensions.hook("onRepairInGarage", vehInvInfo, repairOptionData)
    return startRepair(vehInvInfo.id, repairOptionData, (vehId and repairOption.repairTime <= 0) and function(vehInfo)
        local vehObj = getObjectByID(vehId)
        if not vehObj then
            return
        end
        freeroam_facilities.teleportToGarage(career_modules_inventory.getClosestGarage().id, vehObj, false)
    end)
end

local function genericVehNeedsRepair(vehId, callback)
    local veh = getObjectByID(vehId)
    if not veh then
        return
    end
    local label = logBookLabel or "Repaired vehicle"
    core_vehicleBridge.requestValue(veh, function(res)
        local needsRepair = career_modules_valueCalculator.partConditionsNeedRepair(res.result)
        callback(needsRepair)
    end, 'getPartConditions')
end

-- used to renew insurance policies
local function updateDistanceDriven(dtReal)
    local plId = be:getPlayerVehicleID(0)
    if not career_modules_inventory.getInventoryIdFromVehicleId(plId) then
        return
    end

    local vehicleData = map.objects[plId]
    if not vehicleData then
        return
    end

    if lastPos ~= vec3Zero then
        local dist = lastPos:distance(vehicleData.pos)
        if (dist < 0.001) then
            return
        end -- should use some dt to more accurately discard low numbers when stationary
        plPoliciesData[tostring(currApplicablePolicyId)].totalMetersDriven = plPoliciesData[tostring(currApplicablePolicyId)].totalMetersDriven + dist
    end

    lastPos:set(vehicleData.pos)
end

local function calculatePremiumDetails(policyId, overiddenPerks)
    local premiumDetails = { perksPriceDetails = {}, price = 0 }
    local policyInfo = availablePolicies[policyId]
    if not policyInfo or not policyInfo.perks then return premiumDetails end

    -- renewal multiplier (x1 for the shortest period)
    local renewalChoices = policyInfo.perks.renewal and policyInfo.perks.renewal.changeability and policyInfo.perks.renewal.changeability.changeParams and policyInfo.perks.renewal.changeability.changeParams.choices
    local renewalValue = (overiddenPerks and overiddenPerks ~= nil) and overiddenPerks.renewal or getPlPerkValue(policyInfo.id, "renewal")
    local renewalIndex = (renewalChoices and tableFindKey(renewalChoices, renewalValue)) or 1
    local renewalFactor = 1
    do
        local ca = policyInfo.perks.renewal and policyInfo.perks.renewal.changeability
        if ca and ca.changeParams then
            local infl = ca.changeParams.premiumInfluence
            if type(infl) == "table" then
                renewalFactor = infl[renewalIndex] or 1
            else
                renewalFactor = infl or 1
            end
        end
    end

    -- sum all other perks (additive costs), exclude renewal
    local additiveSum = 0
    for perkName, perkData in pairs(policyInfo.perks) do
        if perkName ~= "renewal" then
            local perkValue = getPlPerkValue(policyId, perkName)
            if overiddenPerks and overiddenPerks[perkName] ~= nil then
                perkValue = overiddenPerks[perkName]
            end

            local value = 0
            local ca = perkData.changeability
            if ca and ca.changeable and ca.changeParams then
                local choices = ca.changeParams.choices
                local infl = ca.changeParams.premiumInfluence
                local index = (choices and tableFindKey(choices, perkValue)) or 1
                if type(infl) == "table" then
                    value = infl[index] or 0
                else
                    value = infl or 0
                end
            else
                value = (ca and ca.premiumInfluence) or 0
            end
            additiveSum = additiveSum + value
            premiumDetails.perksPriceDetails[perkName] = { perk = perkData, price = value }
        end
    end

    local renewalAdditive = math.max(0, renewalFactor - 1) * additiveSum
    premiumDetails.perksPriceDetails["renewal"] = { perk = policyInfo.perks.renewal, price = math.floor(renewalAdditive * 100) / 100 }
    premiumDetails.price = math.floor(additiveSum * renewalFactor * 100) / 100
    return premiumDetails
end

-- per-vehicle premium: all perks except 'renewal' can be overridden per vehicle
-- 'renewal' remains shared at the policy level
local function calculatePremiumDetailsForVehicle(policyId, invId)
    local premiumDetails = { perksPriceDetails = {}, price = 0 }
    local policyInfo = availablePolicies[policyId]
    if not policyInfo then return premiumDetails end

    local renewalChoices = policyInfo.perks.renewal and policyInfo.perks.renewal.changeability and policyInfo.perks.renewal.changeability.changeParams and policyInfo.perks.renewal.changeability.changeParams.choices
    local renewalValue = getPlPerkValue(policyId, "renewal")
    local renewalIndex = (renewalChoices and tableFindKey(renewalChoices, renewalValue)) or 1

    local renewalFactor = 1
    do
        local ca = policyInfo.perks.renewal and policyInfo.perks.renewal.changeability
        if ca and ca.changeParams then
            local infl = ca.changeParams.premiumInfluence
            if type(infl) == "table" then
                renewalFactor = infl[renewalIndex] or 1
            else
                renewalFactor = infl or 1
            end
        end
    end

    local additiveSum = 0
    for perkName, perkData in pairs(policyInfo.perks) do
        if perkName ~= "renewal" then
            local perkValue = getVehPerkValue(invId, perkName)
            local value = 0
            local ca = perkData.changeability
            if ca and ca.changeable and ca.changeParams then
                local choices = ca.changeParams.choices
                local infl = ca.changeParams.premiumInfluence
                local index = (choices and tableFindKey(choices, perkValue)) or 1
                if type(infl) == "table" then
                    value = infl[index] or 0
                else
                    value = infl or 0
                end
            else
                value = (ca and ca.premiumInfluence) or 0
            end
            additiveSum = additiveSum + value
            premiumDetails.perksPriceDetails[perkName] = { perk = perkData, price = value }
        end
    end

    local renewalAdditive = math.max(0, renewalFactor - 1) * additiveSum
    premiumDetails.perksPriceDetails["renewal"] = { perk = policyInfo.perks.renewal, price = math.floor(renewalAdditive * 100) / 100 }
    premiumDetails.price = math.floor(additiveSum * renewalFactor * 100) / 100
    return premiumDetails
end

-- simple premium: sum of each perk's premiumInfluence based on selected indices, no renewal factor, no bonus
local function calculateSimplePremiumSum(policyId, overridesIdx0, invId)
    local policy = availablePolicies[policyId]
    if not policy then return 0 end

    local additive = 0
    local renewalFactor = 1

    for perkName, perkData in pairs(policy.perks or {}) do
        local ca = perkData.changeability and perkData.changeability.changeParams
        if perkName == 'renewal' then
            if ca then
                local choices = ca.choices
                local infl = ca.premiumInfluence
                local idx0
                if overridesIdx0 and overridesIdx0[perkName] ~= nil then
                    idx0 = math.floor(overridesIdx0[perkName])
                else
                    local pi = plPoliciesData[tostring(policyId)]
                    local baseIdx1 = pi and pi.perks and pi.perks[perkName] or 1
                    idx0 = baseIdx1 - 1
                end
                idx0 = math.max(0, math.min((idx0 or 0), (choices and #choices > 0 and #choices - 1 or 0)))
                if type(infl) == 'table' then
                    renewalFactor = infl[idx0 + 1] or 1
                else
                    renewalFactor = infl or 1
                end
            end
        else
            if ca then
                local choices = ca.choices
                local infl = ca.premiumInfluence
                local idx0
                if overridesIdx0 and overridesIdx0[perkName] ~= nil then
                    idx0 = math.floor(overridesIdx0[perkName])
                elseif invId then
                    local overrides = vehiclePerksOverrides[tostring(invId)] or {}
                    if overrides[perkName] ~= nil then
                        idx0 = overrides[perkName]
                    else
                        local pi = plPoliciesData[tostring(policyId)]
                        local baseIdx1 = pi and pi.perks and pi.perks[perkName] or 1
                        idx0 = baseIdx1 - 1
                    end
                else
                    local pi = plPoliciesData[tostring(policyId)]
                    local baseIdx1 = pi and pi.perks and pi.perks[perkName] or 1
                    idx0 = baseIdx1 - 1
                end
                idx0 = math.max(0, math.min((idx0 or 0), (choices and #choices > 0 and #choices - 1 or 0)))
                local price
                if type(infl) == 'table' then
                    price = infl[idx0 + 1] or 0
                else
                    price = infl or 0
                end
                additive = additive + (price or 0)
            else
                local infl = perkData.changeability and perkData.changeability.premiumInfluence
                additive = additive + (infl or 0)
            end
        end
    end

    return math.floor((additive * renewalFactor) * 100) / 100
end

local function getPremiumWithPolicyScoreForVehicle(policyId, invId)
    local base = calculatePremiumDetailsForVehicle(policyId, invId).price
    local bonus = (plPoliciesData[tostring(policyId)] and plPoliciesData[tostring(policyId)].bonus) or 1
    local cappedBonus = math.min(bonus, 35)
    return base * cappedBonus
end

local function getPremiumWithPolicyScore(policyId)
    local basePremium = calculatePremiumDetails(policyId).price
    local bonus = (plPoliciesData[tostring(policyId)] and plPoliciesData[tostring(policyId)].bonus) or 1
    local cappedBonus = math.min(bonus, 35) -- Cap the bonus at 35
    return basePremium * cappedBonus
end

-- overiddenPerks param is there only for the UI. Allows to calculate the premium of a non-existing policy
local function calculatePolicyPremium(policyId, overiddenPerks)
    local policyInfo = availablePolicies[policyId]
    local plPolicyInfo = plPoliciesData[tostring(policyId)] or { bonus = 1 }
    local premium = 0

    for perkName, perkData in pairs(policyInfo.perks) do
        local ca = perkData.changeability
        local perkValue = getPlPerkValue(policyId, perkName)
        if overiddenPerks and overiddenPerks[perkName] ~= nil then
            perkValue = overiddenPerks[perkName]
        end
        if perkName ~= "renewal" and ca and ca.changeable and ca.changeParams then
            local choices = ca.changeParams.choices
            local infl = ca.changeParams.premiumInfluence
            local index = (choices and tableFindKey(choices, perkValue)) or 1
            if type(infl) == "table" then
                premium = premium + (infl[index] or 0)
            else
                premium = premium + (infl or 0)
            end
        elseif perkName ~= "renewal" then
            premium = premium + ((ca and ca.premiumInfluence) or 0)
        end
    end

    -- apply renewal as multiplier
    local renewalChoices = policyInfo.perks.renewal and policyInfo.perks.renewal.changeability and policyInfo.perks.renewal.changeability.changeParams and policyInfo.perks.renewal.changeability.changeParams.choices
    local renewalValue = (overiddenPerks and overiddenPerks ~= nil) and overiddenPerks.renewal or getPlPerkValue(policyId, "renewal")
    local renewalIndex = (renewalChoices and tableFindKey(renewalChoices, renewalValue)) or 1
    local perkPriceScale = (policyInfo.perkPriceScale and policyInfo.perkPriceScale[renewalIndex]) or 1
    local renewalFactor = 1
    do
        local ca = policyInfo.perks.renewal and policyInfo.perks.renewal.changeability
        if ca and ca.changeParams then
            local infl = ca.changeParams.premiumInfluence
            if type(infl) == "table" then
                renewalFactor = infl[renewalIndex] or 1
            else
                renewalFactor = infl or 1
            end
        end
    end

    return (premium * perkPriceScale * renewalFactor) * plPolicyInfo.bonus
end

-- returns true if there has been any claim recorded after the last renewal (or initial purchase if never renewed)
local function hasClaimsSinceLastRenewal(policyId)
    local hist = plHistory and plHistory.policyHistory and plHistory.policyHistory[tostring(policyId)]
    if not hist then return false end
    local lastRenewalTime = 0
    do
        local rp = hist.renewedPolicy
        if rp and #rp > 0 then
            local t = rp[#rp].time
            if type(t) == 'number' and t > 0 then lastRenewalTime = t end
        else
            local ip = hist.initialPurchase and hist.initialPurchase.purchaseTime
            if type(ip) == 'number' and ip > 0 then lastRenewalTime = ip end
        end
    end
    for _, claim in ipairs(hist.claims or {}) do
        local ct = (type(claim.time) == 'number' and claim.time > 0) and claim.time or 0
        if ct > lastRenewalTime then return true end
    end
    return false
end

local function checkRenewPolicy(policyId)
    -- Keep policyId as string, but convert for numeric comparison
    local policyIdNum = tonumber(policyId) or 0
    if not policyId or policyIdNum <= 0 then return end
    if not availablePolicies[policyIdNum] then return end
    -- shared renewal per policy: accumulate time whenever ANY vehicle with this policy is driven
    policyElapsedSeconds[tostring(policyId)] = policyElapsedSeconds[tostring(policyId)] or 0
    local renewalSeconds = getPlPerkValue(policyIdNum, "renewal")
    if not renewalSeconds or renewalSeconds <= 0 then return end
    if policyElapsedSeconds[tostring(policyId)] > renewalSeconds then
        -- charge per-vehicle premiums, shared renewal period
        local premium = 0
        local chargedVehicles = 0
        for invId, assigned in pairs(insuredInvVehs) do
            local assignedNum = tonumber(assigned) or 0
            if math.abs(assignedNum) == policyIdNum and assignedNum >= 0 then
                premium = premium + getPremiumWithPolicyScoreForVehicle(policyIdNum, tonumber(invId))
                chargedVehicles = chargedVehicles + 1
            end
        end
        if chargedVehicles == 0 then
            policyElapsedSeconds[tostring(policyId)] = 0
            return
        end

        table.insert(plHistory.policyHistory[tostring(policyId)].renewedPolicy, { time = os.time(), price = premium })
        local polName = (availablePolicies[policyIdNum] and availablePolicies[policyIdNum].name) or tostring(policyId)
        local label = string.format("Insurance renewed! Tier: %s (-%0.2f$) (%d vehicle%s)", polName, premium, chargedVehicles, chargedVehicles == 1 and "" or "s")
        local logBookLabel = string.format("Insurance renewed! Tier: %s", polName)
        career_modules_payment.pay({ money = { amount = premium, canBeNegative = true } }, { label = logBookLabel })
        policyTows[tostring(policyId)] = getPlPerkValue(policyIdNum, "roadsideAssistance") or 0

        -- Decrease insurance score during renewal only if there were no accidents since last renewal
        if plPoliciesData[tostring(policyId)] and not hasClaimsSinceLastRenewal(policyId) then
            local bonusDecrease = 0.05
            local oldBonus = plPoliciesData[tostring(policyId)].bonus
            plPoliciesData[tostring(policyId)].bonus = math.floor(plPoliciesData[tostring(policyId)].bonus * (1 - bonusDecrease) * 100) / 100
            if plPoliciesData[tostring(policyId)].bonus < 0.5 then
                plPoliciesData[tostring(policyId)].bonus = 0.5
            end
            label = label .. "\n" .. string.format("Insurance policy '%s' score decreased to %0.2f during renewal (no accidents)",
            availablePolicies[policyIdNum].name, plPoliciesData[tostring(policyId)].bonus)
        end

        guihooks.trigger("toastrMsg", {type = "info", title = "Insurance", msg = label})

        policyElapsedSeconds[tostring(policyId)] = 0
    end
end

local function getActualRepairPrice(vehInvInfo)
    -- This function returns the actual price of the repair, taking into account the deductible and the price of the repair without the policy
    -- You will pay the lower value as a deductible is the max you will pay not the lowest
    if not vehInvInfo or not vehInvInfo.id then
        log("W", "insurance", "Invalid vehicle info provided to getActualRepairPrice")
        return 0
    end

    local assignedPolicyId = insuredInvVehs[tostring(vehInvInfo.id)] or 0
    if assignedPolicyId == 0 then
        local repairDetails = career_modules_valueCalculator.getRepairDetails(vehInvInfo)
        if not repairDetails then
            log("W", "insurance", "Failed to get repair details for vehicle")
            return 0
        end
        return repairDetails.price or 0
    end
    local deductiblePct = getPlPerkValue(assignedPolicyId, "deductible") or 0
    local vehicleValue = career_modules_valueCalculator.getInventoryVehicleValue(vehInvInfo.id, true) or 0
    local price = vehicleValue * (deductiblePct / 100)

    local repairDetails = career_modules_valueCalculator.getRepairDetails(vehInvInfo)
    if not repairDetails then
        log("W", "insurance", "Failed to get repair details for vehicle")
        return 0
    end
    local repairPrice = repairDetails.price or 0

    return math.floor(math.min(price * 100, repairPrice * 80)) / 100
end

local originComputerId
local vehicleToRepairData
-- used in the garage computer
local function getRepairData()
    local data = {}
    local vehInfo = deepcopy(vehicleToRepairData)
    local policyId = insuredInvVehs[tostring(vehInfo.id)] or 0
    if not policyId then policyId = 0 end
    local policyInfo = {
        hasFreeRepair = plPoliciesData[tostring(policyId)] and plPoliciesData[tostring(policyId)].hasFreeRepair or false,
        policeFreeRepairAvailable = plPoliciesData[tostring(policyId)] and plPoliciesData[tostring(policyId)].policeFreeRepairAvailable or false,
        name = (availablePolicies[policyId] and availablePolicies[policyId].name) or "No Insurance"
    }

    local repairOptionsSanitized = {}
    for repairOptionName, repairOptionFunction in pairs(repairOptions) do
        local repairOption = repairOptionFunction(vehInfo)
        if repairOption and not repairOption.hideInComputer then
            local repairOptionSanitized = {
                priceOptions = {},
                isPolicyRepair = repairOption.isPolicyRepair,
                repairName = repairOption.repairName,
                repairTime = repairOption.repairTime
            }
            for _, priceOption in pairs(repairOption.priceOptions) do
                local mergedPrice, canBeNegative = mergeRepairOptionPrices(priceOption)
                table.insert(repairOptionSanitized.priceOptions, {
                    prices = deepcopy(priceOption),
                    canPay = career_modules_payment.canPay(mergedPrice),
                    canBeNegative = canBeNegative
                })
            end
            repairOptionsSanitized[repairOptionName] = repairOptionSanitized
        end
    end

    -- No Insurance: only allow private repair
    if policyId == 0 then
        repairOptionsSanitized = { repairNoInsurance = repairOptionsSanitized.repairNoInsurance }
    end

    local thumbnail = career_modules_inventory.getVehicleThumbnail(vehInfo.id)
    vehInfo.thumbnail = (thumbnail or "") .. "?" .. (vehInfo.dirtyDate or "")
    local fullcost = 0
    local deductible = 0

    if repairOptionsSanitized["repairNoInsurance"] and repairOptionsSanitized["repairNoInsurance"].priceOptions and repairOptionsSanitized["repairNoInsurance"].priceOptions[1] and repairOptionsSanitized["repairNoInsurance"].priceOptions[1].prices and repairOptionsSanitized["repairNoInsurance"].priceOptions[1].prices[1].price.money then
        fullcost = repairOptionsSanitized["repairNoInsurance"].priceOptions[1].prices[1].price.money.amount
    end
    if repairOptionsSanitized["normalRepair"] and repairOptionsSanitized["normalRepair"].priceOptions and repairOptionsSanitized["normalRepair"].priceOptions[1] and repairOptionsSanitized["normalRepair"].priceOptions[1].prices and repairOptionsSanitized["normalRepair"].priceOptions[1].prices[1].price.money then
        deductible = repairOptionsSanitized["normalRepair"].priceOptions[1].prices[1].price.money.amount
    end

    data.policyInfo = policyInfo
    local plBonus = (plPoliciesData[tostring(policyId)] and plPoliciesData[tostring(policyId)].bonus) or 1
    data.policyScoreInfluence = policyId == 0 and 0 or math.floor(((getRateIncrease(vehicleToRepairData.id, fullcost, deductible) * plBonus) - plBonus) * 100) / 100
    data.repairOptions = repairOptionsSanitized
    data.baseDeductible = { money = { amount = (getPlPerkValue(policyId, "deductible") or 0), canBeNegative = true } }
    data.vehicle = vehInfo
    data.playerAttributes = career_modules_playerAttributes.getAllAttributes()
    data.numberOfBrokenParts = career_modules_valueCalculator.getNumberOfBrokenParts(
      career_modules_inventory.getVehicles()[vehInfo.id].partConditions)
    -- If totaled for this policy: only offer total-out and private repair
    if policyId > 0 then
        local vehicleValueUndamaged = career_modules_valueCalculator.getInventoryVehicleValue(vehInfo.id, true) or 0
        local vehicleValueDamaged = career_modules_valueCalculator.getInventoryVehicleValue(vehInfo.id, false) or 0
        local valueLoss = vehicleValueUndamaged - vehicleValueDamaged
        local totalPct = getPlPerkValue(policyId, "totalPercentage") or 100
        local threshold = vehicleValueUndamaged * (totalPct / 100)
        if valueLoss >= threshold then
            data.repairOptions = { repairNoInsurance = data.repairOptions.repairNoInsurance }
            local payout = math.floor(vehicleValueUndamaged * 0.75)
            data.repairOptions.insuranceTotalLoss = {
                isPolicyRepair = true,
                repairName = "Total Out Vehicle",
                repairTime = 0,
                priceOptions = {
                    {
                        prices = {
                            {
                                text = "Pay Out",
                                price = { money = { amount = -payout, canBeNegative = true } }
                            }
                        },
                        canPay = true,
                        canBeNegative = false
                    }
                }
            }
        end
    end
    -- include per-vehicle premium breakdown for UI (renewal is shared, others per-vehicle)
    data.vehiclePremiumDetails = calculatePremiumDetailsForVehicle(policyId, vehInfo.id)
    data.vehiclePremium = getPremiumWithPolicyScoreForVehicle(policyId, vehInfo.id)
    return data
end

local insurancePoliciesMenuOpen = false
local closeMenuAfterSaving
-- can't edit policy perks instantly without delays, or players will cheat the system
local function updateEditPolicyTimer(dt)
    policyElapsedSeconds[tostring(currApplicablePolicyId)] = (policyElapsedSeconds[tostring(currApplicablePolicyId)] or 0) + dt
    local sendDataToUI = false
    for _, plPolicyData in pairs(plPoliciesData) do
        if plPolicyData.nextPolicyEditTimer > 0 then
            plPolicyData.nextPolicyEditTimer = plPolicyData.nextPolicyEditTimer - dt
            sendDataToUI = true
        end
    end
    if sendDataToUI and insurancePoliciesMenuOpen then
        M.sendUIData()
    end
end

-- gestures are commercial gestures, eg give the player a bonus after not having crashed for a while
local data = {}
local function checkPolicyGestures()
    local policyData = availablePolicies[currApplicablePolicyId]
    local plPolicyData = plPoliciesData[tostring(currApplicablePolicyId)]
    if not policyData or not policyData.gestures then return end
    for gestureName, _ in pairs(policyData.gestures) do
        local data = {
            plPolicyData = plPolicyData,
            distRef = 0
        }

        local lastClaim =
          plHistory.policyHistory[tostring(currApplicablePolicyId)].claims[#plHistory.policyHistory[tostring(currApplicablePolicyId)].claims]
        if lastClaim then
            data.distRef = lastClaim.happenedAt
        end

        gestures[gestureName](data)
    end
end

local updateInterval = 5
local updateIntervalTimer = 0
local function onUpdate(dtReal, dtSim, dtRaw)
    updateIntervalTimer = updateIntervalTimer + dtSim
    if updateIntervalTimer >= updateInterval then
        updateIntervalTimer = 0
    else
        return
    end
    if currApplicablePolicyId == nil then return end
    -- Convert to number for comparison but keep as string for storage
    local policyIdNum = tonumber(currApplicablePolicyId) or 0
    if not gameplay_missions_missionManager.getForegroundMissionId() and not gameplay_walk.isWalking() and policyIdNum > 0 then
        checkRenewPolicy(tostring(currApplicablePolicyId))
        checkPolicyGestures()
        updateDistanceDriven(5)
    end
    updateEditPolicyTimer(5)
end

local conditions = {
    applicableValue = function(data, values)
        if not data.vehValue then
            return false
        end
        if values.min and values.max then
            return data.vehValue >= values.min and data.vehValue <= values.max
        elseif values.min and not values.max then
            return data.vehValue >= values.min
        elseif values.max and not values.min then
            return data.vehValue <= values.max
        end
    end,
    population = function(data, values)
        if not data.population then
            return false
        end
        if values.min and values.max then
            return data.population >= values.min and data.population <= values.max
        elseif values.min and not values.max then
            return data.population >= values.min
        elseif values.max and not values.min then
            return data.population <= values.min
        end
    end,
    bodyStyles = function(data, values)
        if not data.bodyStyle then
            return false
        end
        for _, bodyStyle in pairs(values) do
            if data.bodyStyle[bodyStyle] then
                return true
            end
        end
        return false
    end,
    commercialClass = function(data, values)
        if not data.commercialClass then
            return false
        end
        for _, commercialClass in pairs(values) do
            if commercialClass == data.commercialClass then
                return true
            end
        end
    end
}

local function changeVehPolicy(invVehId, toPolicyId)
    if not invVehId or toPolicyId == nil then return end
    if inventoryVehNeedsRepair(invVehId) then
        guihooks.trigger("toastrMsg", {type = "error", title = "Cannot change insurance", msg = "This vehicle cannot change insurance while it is damaged."})
        return
    end
    -- allow changing to any applicable policy (including 0)
    if toPolicyId ~= 0 then
        local allow = M.getApplicablePoliciesForVehicle(invVehId)
        local ok = false
        for _, pid in ipairs(allow or {}) do if pid == toPolicyId then ok = true break end end
        if not ok then return end
    end
    insuredInvVehs[tostring(invVehId)] = math.abs(toPolicyId)
    career_saveSystem.saveCurrent()
    M.sendUIData()
end

-- change vehicle policy with a paperwork fee, without immediate assignment from UI selections
local function applyVehPolicyChange(invVehId, toPolicyId, overridesIdx0)
    if not invVehId or toPolicyId == nil then
        log("W", "insurance", "Invalid parameters for applyVehPolicyChange")
        return
    end

    local currentPolicyId = insuredInvVehs[tostring(invVehId)]
    if toPolicyId == currentPolicyId then
        log("I", "insurance", "Vehicle already has the target policy: " .. tostring(toPolicyId))
        return
    end
    if inventoryVehNeedsRepair(invVehId) then
        guihooks.trigger("toastrMsg", {type = "error", title = "Cannot change insurance", msg = "This vehicle cannot change insurance while it is damaged."})
        return
    end
    if toPolicyId ~= 0 then
        local allow = M.getApplicablePoliciesForVehicle(invVehId)
        local ok = false
        for _, pid in ipairs(allow or {}) do if pid == toPolicyId then ok = true break end end
        if not ok then return end
    end

    local premium = 0
    if toPolicyId ~= 0 then
        premium = calculateSimplePremiumSum(toPolicyId, overridesIdx0, invVehId)
    end

    if premium > 0 then
        local polName = (availablePolicies[toPolicyId] and availablePolicies[toPolicyId].name) or tostring(toPolicyId)
        local ok = career_modules_payment.pay({ money = { amount = premium, canBeNegative = false } }, { label = string.format("Insurance premium paid: %s", polName), tags = {"insurance", "premium"} })
        if not ok then return end
        plHistory.policyHistory[tostring(toPolicyId)] = plHistory.policyHistory[tostring(toPolicyId)] or { changedCoverage = {}, renewedPolicy = {}, claims = {}, freeRepairs = {}, id = toPolicyId, initialPurchase = { purchaseTime = -1, forFree = false } }
        table.insert(plHistory.policyHistory[tostring(toPolicyId)].changedCoverage, { time = os.time(), price = premium })
        if not plPoliciesData[tostring(toPolicyId)].owned then
            plPoliciesData[tostring(toPolicyId)].owned = true
            plHistory.policyHistory[tostring(toPolicyId)].initialPurchase = { purchaseTime = os.time(), forFree = true }
        end
    end

    insuredInvVehs[tostring(invVehId)] = math.abs(toPolicyId)
    if type(overridesIdx0) == 'table' then
        local policy = availablePolicies[toPolicyId]
        vehiclePerksOverrides[tostring(invVehId)] = vehiclePerksOverrides[tostring(invVehId)] or {}
        for perkName, idx0 in pairs(overridesIdx0) do
            if policy and policy.perks[perkName] then
                local ca = policy.perks[perkName].changeability and policy.perks[perkName].changeability.changeParams
                local choices = ca and ca.choices
                if choices then
                    local clamped = math.max(0, math.min(idx0 or 0, #choices > 0 and #choices - 1 or 0))
                    vehiclePerksOverrides[tostring(invVehId)][perkName] = clamped
                end
            end
        end
    end
    career_saveSystem.saveCurrent()
    M.sendUIData()
end

-- optional: set a per-vehicle override for a specific perk (index from choices)
local function setVehPerkOverride(invVehId, perkName, choiceIndex)
    local assigned = insuredInvVehs[tostring(invVehId)]
    if not assigned or assigned <= 0 then return end
    local policyId = math.abs(assigned)
    local policy = availablePolicies[policyId]
    if not policy or not policy.perks[perkName] then return end
    local choices = policy.perks[perkName].changeability and policy.perks[perkName].changeability.changeParams and policy.perks[perkName].changeability.changeParams.choices
    if not choices then return end
    vehiclePerksOverrides[tostring(invVehId)] = vehiclePerksOverrides[tostring(invVehId)] or {}
    vehiclePerksOverrides[tostring(invVehId)][perkName] = math.max(0, math.min(choiceIndex or 0, #choices > 0 and #choices - 1 or 0))
    career_saveSystem.saveCurrent()
    M.sendUIData()
end

-- the actual logic for finding the best, minimum (cheapest) insurance policy for a vehicle
-- should always return at least one insurance policy, or we have a hole in insurance applicable conditions
local function getMinApplicablePolicyId(conditionData)
    if conditionData.isPolice then return 4 end
    if conditionData.isCommercial then return 3 end
    if conditionData.vehValue and conditionData.vehValue > 80000 then return 2 end
    return 1
end

-- return a list of policy ids that are valid for this vehicle based on its properties
local function getApplicablePoliciesForVehicle(invId)

    local veh = career_modules_inventory.getVehicles()[invId]
    if not veh then
        return {0} -- Only no insurance if vehicle not found
    end

    local safeValue = career_modules_valueCalculator.getInventoryVehicleValue(invId, true)
    if not safeValue then
        safeValue = veh.configBaseValue or veh.value or 0
    end

    local conditionData = {
        vehValue = safeValue,
        bodyStyle = veh.BodyStyle or (veh.aggregates and veh.aggregates["Body Style"]) or nil
    }

    if career_modules_inventory.getVehicleRole and career_modules_inventory.getVehicleRole(invId) == 'police' then
        conditionData.isPolice = true
    end

    local ids = {0} -- 0 always available

    -- police-only policy
    if conditionData.isPolice then
        table.insert(ids, 4)
    end

    -- commercial policy by body style
    if conditionData.bodyStyle then
        if conditionData.bodyStyle["Bus"] then
            table.insert(ids, 3)
        elseif conditionData.bodyStyle["Van"] then
            table.insert(ids, 3)
        elseif conditionData.bodyStyle["Semi Truck"] then
            table.insert(ids, 3)
        end
    end

    -- prestige policy when value > 80k
    if conditionData.vehValue and conditionData.vehValue > 80000 then
        table.insert(ids, 2)
    else
        table.insert(ids, 1)
    end
    return ids
end

local function getMinApplicablePolicyFromVehicleShoppingData(data)
    local conditionData = {
        vehValue = data.Value,
        population = data.Population,
        bodyStyle = (data.BodyStyle and data.BodyStyle) or data.aggregates["Body Style"]
    }
    if data["Commercial Class"] then
        conditionData.commercialClass = tonumber(string.match(data["Commercial Class"], "%d+"))
    end
    local isPolice = data.role and data.role == 'police'
    if isPolice then
        return availablePolicies[4]
    end
    if conditionData.bodyStyle and (conditionData.bodyStyle["Bus"] or conditionData.bodyStyle["Van"] or conditionData.bodyStyle["Semi Truck"]) then
        return availablePolicies[3]
    end
    if conditionData.vehValue and conditionData.vehValue > 80000 then
        return availablePolicies[2]
    end
    return availablePolicies[1]
end

local function onEnterVehicleFinished()
    if startRepairVehInfo then
        local vehInfo = career_modules_inventory.getVehicles()[startRepairVehInfo.vehId]
        career_modules_inventory.removeVehicleObject(startRepairVehInfo.vehId)
        startRepairDelayed(vehInfo)
        startRepairVehInfo = nil
    end
end

local function hasLicensePlate(inventoryId)
    for partId, part in pairs(career_modules_partInventory.getInventory()) do
        if part.location == inventoryId then
            if string.find(part.name, "licenseplate") then
                return true
            end
        end
    end
end

local function getPlayerIsCop()
    local vehId = be:getPlayerVehicleID(0)
    if vehId and gameplay_traffic.getTrafficData()[vehId] then
        local role = gameplay_traffic.getTrafficData()[vehId].role.name
        return role == 'police'
    end
    return false
end

local offenseNames = {
    ["speeding"] = "Speeding",
    ["reckless"] = "Reckless Driving",
    ["intersection"] = "Failure to Yield",
    ["racing"] = "Felony Speeding",
    ["wrongWay"] = "Wrong Way",
    ["hitPolice"] = "Hitting a Police Vehicle"
}

local function onPursuitAction(vehId, action, data)
    if gameplay_cab and gameplay_cab.inCab() then
        return
    end
    if not gameplay_missions_missionManager.getForegroundMissionId() and vehId == be:getPlayerVehicleID(0) then
        if action == "arrest" then
            local fine = math.floor(data.score * 130) / 100

            local insuranceRate = 0

            local score = data.score

            if score <= 600 then
                -- For scores up to 600, gradually increase from 1.02 to 1.1
                insuranceRate = 1.02 + (0.08 * (score / 600))
            else
                -- For scores above 600, increase more rapidly and reach 2.0 at 8000
                insuranceRate = 1.1 + (0.9 * (1 - math.exp(-(score - 600) / 2000)))
            end

            insuranceRate = math.floor(insuranceRate * 100) / 100
            local invId
            local policyId
            if career_modules_inventory.getInventoryIdFromVehicleId(vehId) then
                invId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
                if insuredInvVehs[tostring(invId)] then
                    policyId = insuredInvVehs[tostring(invId)]
                end
            end
            if not policyId then
                policyId = 1
            end
            M.changePolicyScore(policyId, insuranceRate)
            if not invId or not hasLicensePlate(invId) then
                fine = fine * 2.5
            end
            if M.hasNoInsurance(invId) then
                fine = fine * 3
            end
            if career_modules_hardcore.isHardcoreMode() then
                fine = fine * 3
            end

            local effectText = {{
                label = "Money",
                value = -fine
            }, {
                label = "New policy score",
                value = plPoliciesData[tostring(policyId)].bonus
            }}

            local offenseNameList = {}
            if data.offenses and type(data.offenses) == "table" then
                for offenseKey, offenseData in pairs(data.offenses) do
                    local offenseName = offenseNames[offenseKey] or offenseKey
                    table.insert(offenseNameList, offenseName)
                end
            end
            -- If no specific offenses, use a default message
            if #offenseNameList == 0 then
                table.insert(offenseNameList, "Traffic Violations")
            end
            local arrested = false
            if data.mode ~= 1 then
                arrested = true
            end

            if arrested then
                career_modules_inventory.addArrest(invId)
            else
                career_modules_inventory.addTicket(invId)
                fine = fine * 0.5
            end

            local eventDescription = (arrested and "Arrested for " or "Ticketed for ") .. table.concat(offenseNameList, ", ")

            if not invId then
                eventDescription = eventDescription .. "(Foreign Vehicle)"
            else
                if not career_modules_inventory.getLicensePlateText(vehId) then
                    eventDescription = eventDescription .. " (No License Plate)"
                end

                if M.hasNoInsurance(invId) then
                    eventDescription = eventDescription .. "\nNo Insurance: Fine tripled."
                end

                if career_modules_hardcore.isHardcoreMode() then
                    eventDescription = eventDescription .. "\nHardcore mode is enabled, all fines are tripled."
                end
            end

            table.insert(plHistory.generalHistory.ticketEvents, {
                type = "arrest",
                time = os.time(),
                policyName = availablePolicies[policyId].name,
                eventDescription = eventDescription,
                effectText = effectText
            })
            career_modules_payment.pay({
                money = {
                    amount = fine,
                    canBeNegative = true
                }
            }, {
                label = eventDescription,
                tags = {"fine", "criminal"}
            })
            local combinedMessage = string.format(
              "%s\nYou have been fined: $%.2f\nYour insurance policy score is now: %.2f",
              eventDescription, fine, plPoliciesData[tostring(policyId)].bonus)
            ui_message(combinedMessage, 8, "Insurance", "info")
            career_saveSystem.saveCurrent()
            vehId = be:getPlayerVehicleID(0)
            local playerTrafficData = gameplay_traffic.getTrafficData()[vehId]
            if playerTrafficData and playerTrafficData.pursuit then
                playerTrafficData.pursuit.mode = 0
                playerTrafficData.pursuit.score = 0
            end

        end
    end
end

local function addTicketEvent(description, effectText, invVehId)
    local policyId = 1
    if invVehId then
        policyId = insuredInvVehs[tostring(invVehId)]
    end
    table.insert(plHistory.generalHistory.ticketEvents, {
        type = "other",
        time = os.time(),
        policyName = availablePolicies[policyId].name,
        eventDescription = description,
        effectText = effectText
    })
end

local function onVehicleSwitched()
    initCurrInsurance()
end

local function onCareerModulesActivated(alreadyInLevel)
    loadPoliciesData()
end

local function onSaveCurrentSaveSlot(currentSavePath)
    savePoliciesData(currentSavePath)
end

-- TODO : write a more modulable history
local function sortByTimeReverse(a, b)
    local at = (a and a.ts) or 0
    local bt = (b and b.ts) or 0
    return at > bt
end
local function buildPolicyHistory()
    -- police tickets event
    local list = {}
    plHistory.generalHistory = plHistory.generalHistory or { ticketEvents = {}, testDriveClaims = {} }
    for _, event in ipairs(plHistory.generalHistory.ticketEvents) do
        if event.eventDescription then
            table.insert(list, {
                ts = (type(event.time) == 'number' and event.time > 0) and event.time or os.time(),
                time = os.date("%c", event.time),
                event = event.eventDescription,
                policyName = event.policyName,
                effect = event.effectText
            })
        else
            table.insert(list, {
                ts = (type(event.time) == 'number' and event.time > 0) and event.time or os.time(),
                time = os.date("%c", event.time),
                event = translateLanguage("insurance.history.event.policeTicket.name",
                  "insurance.history.event.policeTicket.name", true),
                policyName = "General",
                effect = {{
                    label = "Police Effect",
                    value = 0
                }}
            })
        end
    end

    for _, claim in ipairs(plHistory.generalHistory.testDriveClaims) do
        local effectText = {{
            label = "Money",
            value = claim.amount and -claim.amount or 0
        }, {
            label = "New policy score",
            value = claim.policyScore and claim.policyScore or 0
        }}

        local ctime = (type(claim.time) == 'number' and claim.time > 0) and claim.time or os.time()
        table.insert(list, {
            ts = ctime,
            time = os.date("%c", ctime),
            event = claim.reason and claim.reason or "Test drive",
            policyName = availablePolicies[claim.policyId or 1].name,
            effect = effectText
        })
    end

    plHistory.policyHistory = plHistory.policyHistory or {}
    for _, policyHistoryInfo in pairs(plHistory.policyHistory) do
        -- repair claims event
        for _, claim in ipairs(policyHistoryInfo.claims or {}) do
            local effectText = {}
            for currency, amount in pairs(claim.deductible) do
                table.insert(effectText, {
                    label = currency == "money" and "Money" or "Bonus star",
                    value = -amount.amount
                })
            end
            if claim.freeRepair then
                table.insert(effectText, {
                    label = "Accident forgiveness",
                    value = 0
                })
            else
                table.insert(effectText, {
                    label = "New policy score",
                    value = claim.policyScore
                })
            end
            local cltime = (type(claim.time) == 'number' and claim.time > 0) and claim.time or os.time()
            table.insert(list, {
                ts = cltime,
                time = os.date("%c", cltime),
                event = translateLanguage("insurance.history.event.vehicleRepaired.name",
                  "insurance.history.event.vehicleRepaired.name", true) .. claim.vehInfo.niceName,
                policyName = availablePolicies[policyHistoryInfo.id or 1].name,
                effect = effectText
            })
        end

        -- policies initial purchase events; only when we have a valid recorded purchase time
        do
            local pt = policyHistoryInfo.initialPurchase and policyHistoryInfo.initialPurchase.purchaseTime or 0
            if plPoliciesData[tostring(policyHistoryInfo.id)] and plPoliciesData[tostring(policyHistoryInfo.id)].owned and type(pt) == 'number' and pt > 0 then
                local effectText = {{
                    label = "Money",
                    value = policyHistoryInfo.initialPurchase.forFree and -0 or
                      -availablePolicies[policyHistoryInfo.id or 1].initialBuyPrice
                }}
                local timeStr = os.date("%c", pt)
                table.insert(list, {
                    ts = pt,
                    time = timeStr,
                    event = translateLanguage("insurance.history.event.initialPurchase.name",
                      "insurance.history.event.initialPurchase.name", true),
                    policyName = availablePolicies[policyHistoryInfo.id or 1].name,
                    effect = effectText
                })
            end
        end


        -- policy renewed events
        for _, renewedPolicyEvent in ipairs(policyHistoryInfo.renewedPolicy or {}) do
            local effectText = {{
                label = "Money",
                value = -renewedPolicyEvent.price
            }}
            local rtime = (type(renewedPolicyEvent.time) == 'number' and renewedPolicyEvent.time > 0) and renewedPolicyEvent.time or os.time()
            table.insert(list, {
                ts = rtime,
                time = os.date("%c", rtime),
                event = translateLanguage("insurance.history.event.policyRenewed.name",
                  "insurance.history.event.policyRenewed.name", true),
                policyName = availablePolicies[policyHistoryInfo.id or 1].name,
                effect = effectText
            })
        end

        -- changed coverage events
        for _, coverageChangedEvent in ipairs(policyHistoryInfo.changedCoverage or {}) do
            local effectText = {{
                label = "Money",
                value = -coverageChangedEvent.price
            }}
            local ctime2 = (type(coverageChangedEvent.time) == 'number' and coverageChangedEvent.time > 0) and coverageChangedEvent.time or os.time()
            table.insert(list, {
                ts = ctime2,
                time = os.date("%c", ctime2),
                event = translateLanguage("insurance.history.event.coverageChanged.name",
                  "insurance.history.event.coverageChanged.name", true),
                policyName = availablePolicies[policyHistoryInfo.id or 1].name,
                effect = effectText
            })
        end

        -- free repair events
        for _, freeRepairEvent in ipairs(policyHistoryInfo.freeRepairs or {}) do
            local effectText = {{
                label = "Accident forgiveness",
                value = 1
            }}
            local frtime = (type(freeRepairEvent.time) == 'number' and freeRepairEvent.time > 0) and freeRepairEvent.time or os.time()
            table.insert(list, {
                ts = frtime,
                time = os.date("%c", frtime),
                event = translateLanguage("insurance.history.event.accidentForgiveness.name",
                  "insurance.history.event.accidentForgiveness.name", true),
                policyName = availablePolicies[policyHistoryInfo.id or 1].name,
                effect = effectText
            })
        end
    end

    table.sort(list, sortByTimeReverse)

    return list
end

local function sendUIData()
    insurancePoliciesMenuOpen = true

    local data = {
        policiesData = {},
        policyHistory = buildPolicyHistory(),
        careerMoney = career_modules_playerAttributes.getAttributeValue("money"),
        careerVouchers = career_modules_playerAttributes.getAttributeValue("vouchers"),
      vehicles = {},
      activePlans = {}
    }

    -- compute how many vehicles are assigned to each policy id
    local assignedCounts = {}
    for invId, assigned in pairs(insuredInvVehs) do
        local pid = math.abs(assigned or 0)
        assignedCounts[pid] = (assignedCounts[pid] or 0) + 1
    end

  -- build active plans summary; always include No Insurance (0) card if any vehicles assigned or unassigned
  local plans = {}
  local function pushPlan(pid)
      local policyInfo = availablePolicies[pid]
      local num = assignedCounts[pid] or 0
      local totalPrem = 0
      if pid ~= 0 then
          for invId, assigned in pairs(insuredInvVehs) do
              if math.abs(assigned or 0) == pid and (assigned or 0) >= 0 then
                  totalPrem = totalPrem + getPremiumWithPolicyScoreForVehicle(pid, tonumber(invId))
              end
          end
      end
      table.insert(plans, {
          id = pid,
          name = policyInfo and policyInfo.name or (pid == 0 and "No Insurance" or tostring(pid)),
          bonus = (plPoliciesData[tostring(pid)] and plPoliciesData[tostring(pid)].bonus) or 1,
          vehiclesInsured = num,
          renewalSeconds = getPlPerkValue(pid, "renewal") or 0,
          totalPremium = totalPrem
      })
  end
  -- include No Insurance if any vehicle is effectively uninsured
  if (assignedCounts[0] or 0) > 0 then pushPlan(0) end
  for _, policyInfo in pairs(availablePolicies) do
      local pid = policyInfo.id
      if pid ~= 0 and (assignedCounts[pid] or 0) > 0 then
          pushPlan(pid)
      end
  end
  data.activePlans = plans

    -- only send the required information, not everything
    for _, policyInfo in pairs(availablePolicies) do
        local perks = {}
        -- get player's data concerning this insurance
        local plPolicyData = plPoliciesData[tostring(policyInfo.id)]

        -- Handle cases where policy data doesn't exist
        if not plPolicyData then
            plPolicyData = {
                bonus = 1,
                nextPolicyEditTimer = 0,
                totalMetersDriven = 0,
                policeStops = 0,
                policeFreeRepairAvailable = false,
                perks = {}
            }
        end

        local plData = {
            -- ownership derived from having at least one vehicle assigned to this policy
            owned = (assignedCounts[policyInfo.id] or 0) > 0 or policyInfo.id == 0,
            bonus = plPolicyData.bonus,
            nextPolicyEditTimer = plPolicyData.nextPolicyEditTimer,
            policeStops = plPolicyData.policeStops or 0,
            policeFreeRepairAvailable = plPolicyData.policeFreeRepairAvailable or false
        }

        for plPerkName, plPerkValue in pairs(plPolicyData.perks) do
            perks[plPerkName] = policyInfo.perks[plPerkName]
            perks[plPerkName].plValue = getPlPerkValue(policyInfo.id, plPerkName)
        end

        local plRenewal = getPlPerkValue(policyInfo.id, "renewal") or 0
        local policyData = {
            id = policyInfo.id,
            name = policyInfo.name,
            resetBonus = policyInfo.resetBonus,
            paperworkFees = policyInfo.paperworkFees,
            description = policyInfo.description,
            premium = getPremiumWithPolicyScore(policyInfo.id),
            nextPaymentDist = plRenewal > 0 and (plRenewal - (plPolicyData.totalMetersDriven % plRenewal)) / 1000 or 0,
            initialBuyPrice = policyInfo.initialBuyPrice,
            perks = perks,

            plData = plData
        }

        table.insert(data.policiesData, policyData)
    end
    -- build vehicle list with per-vehicle current/required policy info
    for invId, veh in pairs(career_modules_inventory.getVehicles()) do
        local assigned = insuredInvVehs[tostring(invId)]
        local owned = (veh.owned == true) and (veh.owningOrganization == nil)
        local requiredPolicyId = assigned and math.abs(assigned) or 0
        -- ownership here should reflect inventory, not policy ownership
        local overrides = vehiclePerksOverrides[tostring(invId)] or {}
        local vehiclePerks = {}
        local policyDef = availablePolicies[requiredPolicyId]
        if policyDef and policyDef.perks then
            for perkName, perkInfo in pairs(policyDef.perks) do
                local val = getVehPerkValue(invId, perkName)
                local baseIdx = (plPoliciesData[tostring(requiredPolicyId)] and plPoliciesData[tostring(requiredPolicyId)].perks and plPoliciesData[tostring(requiredPolicyId)].perks[perkName]) or 1
                local idx0 = overrides[perkName]
                if idx0 == nil then idx0 = baseIdx - 1 end
                vehiclePerks[perkName] = { value = val, index = idx0 }
            end
        end
        table.insert(data.vehicles, {
            id = invId,
            name = veh.niceName or tostring(invId),
            thumbnail = career_modules_inventory.getVehicleThumbnail(invId),
            policyId = requiredPolicyId,
            owned = owned,
            perks = vehiclePerks
        })
    end
    -- showFirstLoadPopup()
    guihooks.trigger('insurancePoliciesData', data)
end

-- remove the vehicle from the insuranced vehicles json files
local function onVehicleRemovedFromInventory(inventoryId)
    insuredInvVehs[tostring(inventoryId)] = nil
    vehiclePerksOverrides[tostring(inventoryId)] = nil
    career_saveSystem.saveCurrent()
end

-- apply the minimum applicable insurance to the vehicle, and save it to the json file
local function onVehicleAddedToInventory(data)
    -- Don't override if vehicle already has insurance assigned (from user selection)
    if insuredInvVehs[tostring(data.inventoryId)] then
        return
    end

    local veh = career_modules_inventory.getVehicles()[data.inventoryId]
    if veh and veh.owningOrganization then
        insuredInvVehs[tostring(data.inventoryId)] = 0
        career_saveSystem.saveCurrent()
        return
    elseif data.selectedPolicyId and data.selectedPolicyId >= 0 then
        insuredInvVehs[tostring(data.inventoryId)] = data.selectedPolicyId
        career_saveSystem.saveCurrent()
        return
    end

    local conditionData = {
        vehValue = career_modules_valueCalculator.getInventoryVehicleValue(data.inventoryId, true) or (data.vehicleInfo and data.vehicleInfo.Value) or 0,
        population = data.vehicleInfo and data.vehicleInfo.Population or nil,
        bodyStyle = data.vehicleInfo and ((data.vehicleInfo.BodyStyle and data.vehicleInfo.BodyStyle) or data.vehicleInfo.aggregates["Body Style"]) or nil
    }

    if data.vehicleInfo and data.vehicleInfo["Commercial Class"] then
        conditionData.commercialClass = tonumber(string.match(data.vehicleInfo["Commercial Class"], "%d+"))
    end
    if data.vehicleInfo and data.vehicleInfo["Body Style"] then
        local bs = data.vehicleInfo["Body Style"]
        if bs and (bs["Bus"] or bs["Van"] or bs["Semi Truck"]) then
            conditionData.isCommercial = true
        end
    end
    -- auto-assign police insurance by vehicle role
    if career_modules_inventory.getVehicleRole and career_modules_inventory.getVehicleRole(data.inventoryId) == 'police' then
        insuredInvVehs[tostring(data.inventoryId)] = 4
        career_saveSystem.saveCurrent()
        return
    end

    local requiredPolicyId = getMinApplicablePolicyId(conditionData)
    -- Always assign at least No Insurance (0) to avoid vehicles having no policy entry
    insuredInvVehs[tostring(data.inventoryId)] = requiredPolicyId or 0
    career_saveSystem.saveCurrent()
end

local function openRepairMenu(vehicle, _originComputerId)
    vehicleToRepairData = vehicle
    originComputerId = _originComputerId
    guihooks.trigger('ChangeState', {
        state = 'repair',
        params = {}
    })
end

local function changePolicyPerks(policyId, changedPerks)
    local policyTowsValue = getPlPerkValue(policyId, "roadsideAssistance") or 0
    for perkName, perkValue in pairs(changedPerks) do
        local index = tableFindKey(availablePolicies[policyId].perks[perkName].changeability.changeParams.choices,
          perkValue)
        if plPoliciesData[tostring(policyId)].perks[perkName] ~= nil then
            plPoliciesData[tostring(policyId)].perks[perkName] = index
        end
    end
    policyTows[tostring(policyId)] = (policyTows[tostring(policyId)] or 0) - policyTowsValue + (getPlPerkValue(policyId, "roadsideAssistance") or 0)

    table.insert(plHistory.policyHistory[tostring(policyId)].changedCoverage, {
        time = os.time(),
        price = availablePolicies[policyId].paperworkFees
    })

    local label = string.format("Policy coverage changed. Tier : %s", availablePolicies[policyId].name)
    career_modules_payment.pay({
        money = {
            amount = availablePolicies[policyId].paperworkFees,
            canBeNegative = false
        }
    }, {
        label = label,
        tags = {"insurance"}
    })
    plPoliciesData[tostring(policyId)].nextPolicyEditTimer = policyEditTime
    M.sendUIData()
end

-- close the insurances computer menu
local function closeMenu(_closeMenuAfterSaving)
    closeMenuAfterSaving = career_career.isAutosaveEnabled() and _closeMenuAfterSaving
  
    if not closeMenuAfterSaving then
      if originComputerId then
        local computer = freeroam_facilities.getFacility("computer", originComputerId)
        career_modules_computer.openMenu(computer)
      else
        career_career.closeAllMenus()
      end
    end
  end
  
  local function onVehicleSaveFinished()
    if closeMenuAfterSaving then
      closeMenu()
      closeMenuAfterSaving = nil
    end
  end

-- open the insurances computer menu
local function openMenu(_originComputerId)
    originComputerId = _originComputerId
    if originComputerId then
        guihooks.trigger('ChangeState', {
            state = 'insurancePolicies',
            params = {}
        })
        extensions.hook("onComputerInsurance")
    end
end

local function onExitInsurancePoliciesList()
    insurancePoliciesMenuOpen = false
end

local function onComputerAddFunctions(menuData, computerFunctions)
    if menuData.computerFacility.functions["insurancePolicies"] then
        local computerFunctionData = {
            id = "insurancePolicies",
            label = "Insurance policies",
            callback = function()
                openMenu(menuData.computerFacility.id)
            end,
            order = 15
        }
        if menuData.tutorialPartShoppingActive or menuData.tutorialTuningActive then
            computerFunctionData.disabled = true
            computerFunctionData.reason = career_modules_computer.reasons.tutorialActive
        end
        computerFunctions.general[computerFunctionData.id] = computerFunctionData
    end

    if menuData.computerFacility.functions["vehicleInventory"] then
        for _, vehicleData in ipairs(menuData.vehiclesInGarage) do
            local inventoryId = vehicleData.inventoryId
            local computerFunctionData = {
                id = "repair",
                label = "Repair",
                callback = function()
                    openRepairMenu(career_modules_inventory.getVehicles()[inventoryId], menuData.computerFacility.id)
                end,
                order = 5
            }
            -- tutorial
            if menuData.tutorialPartShoppingActive or menuData.tutorialTuningActive then
                computerFunctionData.disabled = true
                computerFunctionData.reason = {
                    type = "text",
                    label = "Disabled during tutorial. Use the recovery prompt instead."
                }
            end

            -- generic gameplay reason
            local reason = career_modules_permissions.getStatusForTag({"vehicleRepair"}, {
                inventoryId = inventoryId
            })
            if not reason.allow then
                computerFunctionData.disabled = true
            end
            if reason.permission ~= "allowed" then
                computerFunctionData.reason = reason
            end

            computerFunctions.vehicleSpecific[inventoryId][computerFunctionData.id] = computerFunctionData
        end
    end
end

local function payBonusReset(policyId)
    if not policyId or not availablePolicies[policyId] or not plPoliciesData[tostring(policyId)] then
        log("W", "insurance", "Invalid policy data for bonus reset: " .. tostring(policyId))
        return
    end

    local policyData = availablePolicies[policyId]
    if not policyData.resetBonus or not policyData.resetBonus.conditions or not policyData.resetBonus.price then
        log("W", "insurance", "Policy missing reset bonus data: " .. tostring(policyId))
        return
    end

    if plPoliciesData[tostring(policyId)].bonus > policyData.resetBonus.conditions.minBonus and
      career_modules_payment.canPay(policyData.resetBonus.price) then
        local policyName = policyData.name or "Unknown Policy"
        local label = string.format("Policy score decreased. Tier : %s", policyName)
        career_modules_payment.pay(policyData.resetBonus.price, {
            label = label,
            tags = {"insurance", "goodBehaviour"}
        })
        plPoliciesData[tostring(policyId)].bonus = 1
        sendUIData()
    end
end

M.getPolicyDeductible = function(vehInvId)
    -- Enhanced input validation: handle nil, wrong types, and edge cases
    if vehInvId == nil or (type(vehInvId) ~= "number" and type(vehInvId) ~= "string") then
        log("W", "insurance", "Invalid vehicle ID provided to getPolicyDeductible: " .. tostring(vehInvId) .. " - returning 0")
        return 0
    end
    local policyId = insuredInvVehs[tostring(vehInvId)]
    local result = getPlPerkValue(policyId, "deductible") or 0
    return result
end

M.getRepairTime = function(vehInvId)
    -- Enhanced input validation: handle nil, wrong types, and edge cases
    if vehInvId == nil or (type(vehInvId) ~= "number" and type(vehInvId) ~= "string") then
        log("W", "insurance", "Invalid vehicle ID provided to getRepairTime: " .. tostring(vehInvId) .. " - returning 0")
        return 0
    end
    return getPlPerkValue(insuredInvVehs[tostring(vehInvId)], "repairTime") or 0
end

local function getPlayerPolicyData()
    return plPoliciesData
end

local function getQuickRepairExtraPrice()
    return quickRepairExtraPrice
end

local function expediteRepair(inventoryId, price)
    if career_modules_payment.pay({
        money = {
            amount = price,
            canBeNegative = false
        }
    }, {
        label = "Expedited repair"
    }) then
        local vehInfo = career_modules_inventory.getVehicles()[inventoryId]
        vehInfo.timeToAccess = nil
        vehInfo.delayReason = nil
        career_modules_inventory.setVehicleDirty(inventoryId)
    end
end

M.isRoadSideAssistanceFree = function(invVehId)
    local policyId = insuredInvVehs[tostring(invVehId)] or 0
    -- No insurance (policy 0) means towing is NOT free
    if policyId == 0 then
        return false
    end
    local applicablePolicy = plPoliciesData[tostring(policyId)]
    if not applicablePolicy then
        return true
    end
    if policyTows[tostring(applicablePolicy.id)] == nil then
        policyTows[tostring(applicablePolicy.id)] = getPlPerkValue(applicablePolicy.id, "roadsideAssistance") or 0
    end
    local value = policyTows[tostring(applicablePolicy.id)]
    if value and value <= 0 then
        return false
    end
    return true
end

M.useTow = function(invVehId)
    if policyTows[tostring(insuredInvVehs[tostring(invVehId)])] > 0 then
        policyTows[tostring(insuredInvVehs[tostring(invVehId)])] = policyTows[tostring(insuredInvVehs[tostring(invVehId)])] - 1
    end
end
-- For UI
M.getVehPolicyInfo = function(vehInvId)
    local assigned = insuredInvVehs[tostring(vehInvId)]
    if assigned == nil then assigned = 0 end
    local polId = math.abs(assigned)
    return {
        -- treat 0 (No Insurance) as "owned/allowed" so vehicles can be driven without insurance
        policyOwned = (assigned or 0) >= 0,
        policyInfo = availablePolicies[polId]
    }
end
M.getTestDriveClaimPrice = function()
    return testDriveClaimPrice.money.amount
end
M.getPlHistory = function()
    return plHistory
end

M.genericVehNeedsRepair = genericVehNeedsRepair
M.makeRepairClaim = makeRepairClaim
M.makeTestDriveDamageClaim = makeTestDriveDamageClaim
M.startRepairInstant = startRepairInstant
M.startRepair = startRepair
M.inventoryVehNeedsRepair = inventoryVehNeedsRepair
M.missionStartRepairCallback = missionStartRepairCallback
M.openRepairMenu = openRepairMenu
M.getRepairData = getRepairData
M.closeMenu = closeMenu
M.repairPartConditions = repairPartConditions
M.purchasePolicy = purchasePolicy
M.changeVehPolicy = changeVehPolicy
M.applyVehPolicyChange = applyVehPolicyChange
M.setVehPerkOverride = setVehPerkOverride
M.getMinApplicablePolicyFromVehicleShoppingData = getMinApplicablePolicyFromVehicleShoppingData
M.getApplicablePoliciesForVehicle = getApplicablePoliciesForVehicle
M.getPlayerPolicyData = getPlayerPolicyData
M.payBonusReset = payBonusReset
M.getQuickRepairExtraPrice = getQuickRepairExtraPrice
M.expediteRepair = expediteRepair

-- Police-specific functions
local function getPoliceStops()
    return plPoliciesData["4"] and plPoliciesData["4"].policeStops or 0
end

local function hasPoliceFreeRepairAvailable()
    return plPoliciesData["4"] and plPoliciesData["4"].policeFreeRepairAvailable or false
end

local function incrementPoliceStop(invVehId)
    local policyId = insuredInvVehs[tostring(invVehId)]
    if policyId == 4 then -- Police insurance
        if not plPoliciesData["4"] then
            plPoliciesData["4"] = {
                policeStops = 0,
                policeFreeRepairAvailable = false
            }
        end

        plPoliciesData["4"].policeStops = (plPoliciesData["4"].policeStops or 0) + 1

        -- Grant free repair every 3 stops, but only if not already available
        if plPoliciesData["4"].policeStops >= 3 and not (plPoliciesData["4"].policeFreeRepairAvailable or false) then
            plPoliciesData["4"].policeFreeRepairAvailable = true
            plPoliciesData["4"].policeStops = 0 -- reset counter
            ui_message("Police insurance: Free repair earned after 3 stops", 5, "Insurance", "info")
        end
    end
end

local function hasNoInsurance(invVehId)
    local policyId = insuredInvVehs[tostring(invVehId)]
    return policyId == 0 or policyId == nil
end

M.getPoliceStops = getPoliceStops
M.hasPoliceFreeRepairAvailable = hasPoliceFreeRepairAvailable
M.incrementPoliceStop = incrementPoliceStop
M.hasNoInsurance = hasNoInsurance

M.calculatePremiumDetails = calculatePremiumDetails
M.calculatePolicyPremium = calculatePolicyPremium
M.getPremiumWithPolicyScoreForVehicle = getPremiumWithPolicyScoreForVehicle
M.startRepairInGarage = startRepairInGarage
M.openMenu = openMenu
M.sendUIData = sendUIData
M.changePolicyPerks = changePolicyPerks

-- hooks
M.onUpdate = onUpdate
M.onCareerModulesActivated = onCareerModulesActivated
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onComputerAddFunctions = onComputerAddFunctions
M.onVehicleSwitched = onVehicleSwitched
M.onEnterVehicleFinished = onEnterVehicleFinished
M.onExitInsurancePoliciesList = onExitInsurancePoliciesList
M.onPursuitAction = onPursuitAction
M.onVehicleSaveFinished = onVehicleSaveFinished

-- from vehicle inventory
M.onVehicleAddedToInventory = onVehicleAddedToInventory
M.onVehicleRemoved = onVehicleRemovedFromInventory

-- internal use only
M.getActualRepairPrice = getActualRepairPrice
M.getPlPerkValue = getPlPerkValue
M.changePolicyScore = function(invVehId, rate, operation)
    return changePolicyScore(invVehId, rate, operation)
end

-- career debug
M.resetPlPolicyData = function()
    loadPoliciesData(true)
end

M.getVehPerkValue = getVehPerkValue

return M

