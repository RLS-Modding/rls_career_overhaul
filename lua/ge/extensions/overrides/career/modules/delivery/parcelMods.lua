-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
local dParcelManager, dCargoScreen, dGeneral, dGenerator, dProgress, dParcelMods
M.onCareerActivated = function()
    dParcelManager = career_modules_delivery_parcelManager
    dCargoScreen = career_modules_delivery_cargoScreen
    dGeneral = career_modules_delivery_general
    dGenerator = career_modules_delivery_generator
    dProgress = career_modules_delivery_progress
end

local modifiers = {
    timed = {
        unlockFlag = "smallPackagesDelivery",
        makeTemplate = function(g, p, distance)
            local time = (distance / 13) + 30 * math.random() + 30
            return {
                type = "timed",
                timeUntilDelayed = time,
                timeUntilLate = time * 1.25 + 15,
                -- paddingTime = time * 0.2 + 10,
                -- timeMessageFlag = false,
                -- paddingTimeMessageFlag = false,
                moneyMultipler = 1.5
            }
        end,
        unlockLabel = "Time Sensitive Deliveries",
        priority = 1,
        icon = "stopwatchSectionSolidEnd",
        label = "Time Sensitive",
        shortDescription = "Increased rewards when on time, penalty if late.",
        important = true
    },
    post = {
        unlockFlag = "smallPackagesDelivery",
        makeTemplate = function(g, p, distance)
            return {
                type = "post",
                moneyMultipler = 1.2
            }
        end,
        unlockLabel = "General Post Parcels",
        priority = 2,
        icon = "envelope",
        label = "Postage Parcel",
        shortDescription = "",
        hidden = true
    },
    precious = {
        unlockFlag = "largePackagesDelivery",
        penalty = 3,
        makeTemplate = function(g, p, distance)
            return {
                type = "precious",
                moneyMultipler = 2.5,
                abandonMultiplier = 1.0
            }
        end,
        unlockLabel = "Precious Cargo",
        priority = 3,
        icon = "fragile",
        label = "Precious",
        shortDescription = "Increased rewards, high penalty if lost or abandoned.",
        important = true

    },
    supplies = {
        unlockFlag = "largePackagesDelivery",
        makeTemplate = function(g, p, distance)
            return {
                type = "supplies",
                moneyMultipler = 1.0
            }
        end,
        unlockLabel = "Supply & Logistics Cargo",
        priority = 4,
        icon = "cardboardBox",
        label = "Supply & Logistics",
        shortDescription = "",
        hidden = true
    },
    large = {
        unlockFlag = "largePackagesDelivery",
        makeTemplate = function(g, p, distance)
            return {
                type = "large",
                moneyMultipler = 1.2
            }
        end,
        unlockLabel = "Large & Heavy Cargo",
        priority = 5,
        icon = "group",
        label = "Large & Heavy",
        shortDescription = "Drive carefully and beware of momentum!"
    },
    fluid = {
        unlockFlag = "hazardousMaterialsDelivery",
        makeTemplate = function(g, p, distance)
            return {
                type = "fluid"
            }
        end,
        unlockLabel = "Fluids",
        priority = 6,
        icon = "droplet",
        label = "Fluid",
        shortDescription = "Requires a fluid-capable container or tank to transport."
    },
    dryBulk = {
        unlockFlag = "hazardousMaterialsDelivery",
        makeTemplate = function(g, p, distance)
            return {
                type = "dryBulk"
            }
        end,
        unlockLabel = "Dry Bulk",
        priority = 6,
        icon = "rocks",
        label = "Dry Bulk",
        shortDescription = "Requires a drybulk-capable container to transport."
    },
    cement = {
        unlockFlag = "hazardousMaterialsDelivery",
        makeTemplate = function(g, p, distance)
            return {
                type = "cement"
            }
        end,
        unlockLabel = "Cement",
        priority = 6,
        icon = "rocks",
        label = "Cement",
        shortDescription = "Requires a cement-capable container to transport."
    },
    cash = {
        unlockFlag = "smallPackagesDelivery",
        makeTemplate = function(g, p, distance)
            return {
                type = "cash"
            }
        end,
        unlockLabel = "Cash",
        priority = 6,
        icon = "beamCurrency",
        label = "Cash",
        shortDescription = "Requires a cash-capable container to transport."
    },
    parcel = {
        unlockFlag = "smallPackagesDelivery",
        makeTemplate = function(g, p, distance)
            return {
                type = "parcel"
            }
        end,
        unlockLabel = "Parcel",
        priority = 6,
        icon = "cardboardBox",
        label = "Parcel",
        shortDescription = "Requires a parcel-capable container transport.",
        hidden = true
    },
    hazardous = {
        unlockFlag = "hazardousMaterialsDelivery",
        makeTemplate = function(g, p, distance)
            return {
                type = "hazardous"
            }
        end,
        unlockLabel = "Hazardous",
        priority = 6,
        icon = "roadblockL",
        label = "Hazardous",
        shortDescription = "Large penalty if lost or abandoned. Requires special license to handle."

    },
    airExpress = {
        unlockFlag = "smallPackagesDelivery",
        makeTemplate = function(g, p, distance)
            return {
                type = "post",
                moneyMultipler = 40.0
            }
        end,
        unlockLabel = "Air Express Parcels",
        priority = 2,
        icon = "cardboardBox",
        label = "Air Parcel",
        shortDescription = "",
        important = true

    },
    remoteDelivery = {
        unlockFlag = "smallPackagesDelivery",
        makeTemplate = function(g, p, distance)
            return {
                type = "post",
                moneyMultipler = 15.0
            }
        end,
        unlockLabel = "Remote Delivery Parcels",
        priority = 2,
        icon = "cardboardBox",
        label = "Remote Parcel",
        shortDescription = "",
        important = true

    },
    pepperReduction = {
        unlockFlag = "smallPackagesDelivery",
        makeTemplate = function(g, p, distance)
            return {
                type = "post",
                moneyMultipler = 0.5
            }
        end,
        unlockLabel = "Pepper Valley Frieght",
        priority = 2,
        icon = "cardboardBox",
        label = "Remote Parcel",
        shortDescription = "",
        important = true

    }
}

local progressTemplate = {
    timed = {
        delivieries = 0,
        onTimeDeliveries = 0,
        delayedDeliveries = 0,
        lateDeliveries = 0
    },
    large = {
        delivieries = 0
    },
    precious = {
        delivieries = 0,
        lost = 0
    },
    heavy = {
        delivieries = 0
    },
    post = {
        delivieries = 0
    },
    airExpress = {
        delivieries = 0
    },
    remoteDelivery = {
        delivieries = 0
    },
    pepperReduction = {
        delivieries = 0
    }
}

local progress = deepcopy(progressTemplate)


local function calculateTimedModifierTime(distance)
    local r = math.random() + 1
    return (distance / 13) + (30 * r)
end

local sortByPrio = function(a, b)
    return modifiers[a.type].priority < modifiers[b.type].priority
end

local modifierProbability = 1
local largeSlotThreshold = 65
local heavyWeightThreshold = 80
local function generateModifiers(item, parcelTemplate, distance)
    local mods = {}
    math.randomseed(item.groupSeed)

    local r = math.random()
    -- for _, modKey in ipairs(tableKeysSorted(modifiers)) do
    for _, modKey in ipairs(tableKeysSorted(parcelTemplate.modChance)) do
        if r <= parcelTemplate.modChance[modKey] then
            local modTemplate = modifiers[modKey].makeTemplate(item.groupSeed, parcelTemplate, distance)
            table.insert(mods, modTemplate)
        end
        r = math.random()
    end

    if item.slots >= largeSlotThreshold or item.weight >= heavyWeightThreshold and not parcelTemplate.modChance.large then
        table.insert(mods, modifiers.large.makeTemplate())
    end

    table.sort(mods, sortByPrio)
    return mods
end

local function isParcelModUnlocked(modKey)
    if not modifiers[modKey] or not modifiers[modKey].unlockFlag then
        return false
    end
    return career_modules_unlockFlags.getFlag(modifiers[modKey].unlockFlag)
end

local function lockedBecauseOfMods(modKeys)
    local minTier = 1
    local locked = false
    local definitions = {}
    for key, _ in pairs(modKeys) do
        if modifiers[key] and modifiers[key].unlockFlag then
            local unlockFlag = modifiers[key].unlockFlag
            local flagDefinition = career_modules_unlockFlags.getFlagDefinition(unlockFlag)
            table.insert(definitions, flagDefinition)
            if not career_modules_unlockFlags.getFlag(unlockFlag) then
                locked = true
            end
        end
    end
    table.sort(definitions, function(a, b)
        return (a and a.level or 0) > (b and b.level or 0)
    end)
    return locked, definitions[1]
end

local function getParcelModUnlockStatusSimple()
    local status = {}
    for modKey, info in pairs(modifiers) do
        status[modKey] = isParcelModUnlocked(modKey)
    end
    return status
end


local function trackModifierStats(cargo)
    for _, mod in ipairs(cargo.modifiers or {}) do
        progress[mod.type] = progress[mod.type] or {}
        progress[mod.type].delivered = (progress[mod.type].delivered or 0) + 1
        if mod.type == "timed" then
            local prog = progress.timed
            local expiredTime = dGeneral.time() - cargo.loadedAtTimeStamp

            if expiredTime <= mod.timeUntilDelayed then
                prog.onTimeDeliveries = (prog.onTimeDeliveries or 0) + 1
            elseif expiredTime <= mod.timeUntilLate then
                prog.delayedDeliveries = (prog.delayedDeliveries or 0) + 1
            else
                prog.lateDeliveries = (prog.lateDeliveries or 0) + 1
            end
        end
    end
end

local function addModifier(key, mod)
    if not key or type(key) ~= "string" or key == "" then
        log("E", "parcelMods", "addModifier: Invalid modifier key")
        return false
    end
    
    if not mod or type(mod) ~= "table" then
        log("E", "parcelMods", "addModifier: Modifier data must be a table")
        return false
    end
    
    if modifiers[key] then
        log("W", "parcelMods", "addModifier: Modifier '" .. key .. "' already exists, overwriting")
    end
    
    if not mod.makeTemplate or type(mod.makeTemplate) ~= "function" then
        log("E", "parcelMods", "addModifier: Modifier '" .. key .. "' missing required 'makeTemplate' function")
        return false
    end
    
    if not mod.unlockFlag or type(mod.unlockFlag) ~= "string" then
        log("E", "parcelMods", "addModifier: Modifier '" .. key .. "' missing required 'unlockFlag' string")
        return false
    end
    
    if not mod.unlockLabel or type(mod.unlockLabel) ~= "string" then
        log("E", "parcelMods", "addModifier: Modifier '" .. key .. "' missing required 'unlockLabel' string")
        return false
    end
    
    if not mod.priority or type(mod.priority) ~= "number" then
        log("E", "parcelMods", "addModifier: Modifier '" .. key .. "' missing required 'priority' number")
        return false
    end
    
    if not mod.icon or type(mod.icon) ~= "string" then
        log("E", "parcelMods", "addModifier: Modifier '" .. key .. "' missing required 'icon' string")
        return false
    end
    
    if not mod.label or type(mod.label) ~= "string" then
        log("E", "parcelMods", "addModifier: Modifier '" .. key .. "' missing required 'label' string")
        return false
    end
    
    modifiers[key] = mod
    
    if not progressTemplate[key] then
        progressTemplate[key] = {
            delivieries = 0
        }
    end
    
    log("I", "parcelMods", "addModifier: Successfully added modifier '" .. key .. "'")
    return true
end

M.setProgress = function(data)
    progress = data or deepcopy(progressTemplate)
end

M.getProgress = function()
    return progress
end

M.getModData = function(key)
    return modifiers[key]
end

M.getModifierIcon = function(key)
    return modifiers[key].icon
end

M.getLabelAndShortDescription = function(key)
    return modifiers[key].label, modifiers[key].shortDescription
end

M.isImportant = function(key)
    return modifiers[key].important or false
end

M.addModifier = addModifier
M.calculateTimedModifierTime = calculateTimedModifierTime
M.generateModifiers = generateModifiers
M.isParcelModUnlocked = isParcelModUnlocked
M.lockedBecauseOfMods = lockedBecauseOfMods
M.trackModifierStats = trackModifierStats
M.getParcelModUnlockStatusSimple = getParcelModUnlockStatusSimple
M.getParcelModProgressLabel = function(key)
    return modifiers[key].unlockLabel
end


return M
