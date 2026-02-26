-- Shared parcel modifier definitions and logic
-- Extracted from career/modules/delivery/parcelMods.lua
-- These functions do NOT require career mode to be active.

local M = {}

local modifiers = {
  timed = {
    unlockFlag = "smallPackagesDelivery",
    makeTemplate = function(g, p, distance)
      local time = (distance / 13) + 30 * math.random() + 30
      return {
        type = "timed",
        timeUntilDelayed = time,
        timeUntilLate = time * 1.25 + 15,
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

local function calculateTimedModifierTime(distance)
  local r = math.random() + 1
  return (distance / 13) + (30 * r)
end

local sortByPrio = function(a, b)
  return modifiers[a.type].priority < modifiers[b.type].priority
end

local largeSlotThreshold = 65
local heavyWeightThreshold = 80
local function generateModifiers(item, parcelTemplate, distance)
  local mods = {}
  math.randomseed(item.groupSeed)

  local r = math.random()
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

-- Check if a parcel mod is unlocked.
-- unlockedFlags: optional table of {unlockFlagName = true/false}
-- If nil, all mods are treated as unlocked (non-career mode).
local function isParcelModUnlocked(modKey, unlockedFlags)
  if not modifiers[modKey] or not modifiers[modKey].unlockFlag then
    return false
  end
  if unlockedFlags then
    return unlockedFlags[modifiers[modKey].unlockFlag] or false
  end
  return true -- no flags = everything unlocked
end

-- Check if any mod in modKeys is locked.
-- unlockedFlags: optional table of {unlockFlagName = true/false}
-- flagDefinitions: optional table of {unlockFlagName = definitionTable}
-- If unlockedFlags is nil, nothing is locked (non-career mode).
local function lockedBecauseOfMods(modKeys, unlockedFlags, flagDefinitions)
  local locked = false
  local definitions = {}
  for key, _ in pairs(modKeys) do
    if modifiers[key] and modifiers[key].unlockFlag then
      local unlockFlag = modifiers[key].unlockFlag
      if flagDefinitions then
        local flagDef = flagDefinitions[unlockFlag]
        if flagDef then
          table.insert(definitions, flagDef)
        end
      end
      if unlockedFlags then
        if not unlockedFlags[unlockFlag] then
          locked = true
        end
      end
      -- if no flags provided, not locked
    end
  end
  table.sort(definitions, function(a, b)
    return (a and a.level or 0) > (b and b.level or 0)
  end)
  return locked, definitions[1]
end

-- Get unlock status for all mods.
-- unlockedFlags: optional table of {unlockFlagName = true/false}
-- If nil, all mods are treated as unlocked.
local function getParcelModUnlockStatusSimple(unlockedFlags)
  local status = {}
  for modKey, info in pairs(modifiers) do
    status[modKey] = isParcelModUnlocked(modKey, unlockedFlags)
  end
  return status
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

  log("I", "parcelMods", "addModifier: Successfully added modifier '" .. key .. "'")
  return true
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

M.getParcelModProgressLabel = function(key)
  return modifiers[key].unlockLabel
end

M.getModifiers = function()
  return modifiers
end

M.addModifier = addModifier
M.calculateTimedModifierTime = calculateTimedModifierTime
M.generateModifiers = generateModifiers
M.isParcelModUnlocked = isParcelModUnlocked
M.lockedBecauseOfMods = lockedBecauseOfMods
M.getParcelModUnlockStatusSimple = getParcelModUnlockStatusSimple

return M
