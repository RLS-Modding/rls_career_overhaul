-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Parcel modifier definitions, compatibility and timed-delivery rules; queries also work with no career.
-- Read definitions, availability checks, generation and registration; missing map modifiers are isolated from known ones.
local M = {}
local catalog = require("overhaul/lib/platform/jsonCatalog")

-- Config ------------------------------------------------------------------------------------------

-- A makeTemplate for modifiers that only tag the parcel with their type.
local function typeTemplate(modType)
  return function() return { type = modType } end
end

-- Registry of parcel modifiers. addModifier can extend it at runtime. Slot tiers are gated by unlock flags; the parcel's slot count decides which tier applies.
local modifiers = {
  timed = {
    unlockFlag = "smallPackagesDelivery", priority = 1, important = true,
    icon = "stopwatchSectionSolidEnd",
    unlockLabel = "ui.career.delivery.parcelMods.timed.unlockLabel",
    label = "ui.career.delivery.parcelMods.timed.label",
    shortDescription = "ui.career.delivery.parcelMods.timed.description",
    makeTemplate = function(g, p, distance)
      local time = (distance / 13) + 30 * math.random() + 30
      return { type = "timed", timeUntilDelayed = time, timeUntilLate = time * 1.25 + 15, moneyMultipler = 1.5 }
    end,
  },
  post = {
    unlockFlag = "smallPackagesDelivery", priority = 2, hidden = true,
    icon = "envelope",
    unlockLabel = "ui.career.delivery.parcelMods.post.unlockLabel",
    label = "ui.career.delivery.parcelMods.post.label",
    shortDescription = "",
    makeTemplate = function(g, p, distance) return { type = "post", moneyMultipler = 1.2 } end,
  },
  precious = {
    -- Keep medium parcel variants aligned with the 32-slot gate.
    unlockFlag = "logisticsParcel32Slots", penalty = 3, priority = 3, important = true,
    icon = "fragile",
    unlockLabel = "ui.career.delivery.parcelMods.precious.unlockLabel",
    label = "ui.career.delivery.parcelMods.precious.label",
    shortDescription = "ui.career.delivery.parcelMods.precious.description",
    makeTemplate = function(g, p, distance)
      return { type = "precious", moneyMultipler = 2.5, abandonMultiplier = 1.0 }
    end,
  },
  supplies = {
    -- Keep medium parcel variants aligned with the 32-slot gate.
    unlockFlag = "logisticsParcel32Slots", priority = 4, hidden = true,
    icon = "cardboardBox",
    unlockLabel = "ui.career.delivery.parcelMods.supplies.unlockLabel",
    label = "ui.career.delivery.parcelMods.supplies.label",
    shortDescription = "",
    makeTemplate = function(g, p, distance) return { type = "supplies", moneyMultipler = 1.0 } end,
  },
  -- Large/heavy modifier can appear on different slot sizes; slot gates will handle exact tier.
  large = {
    unlockFlag = "logisticsParcel32Slots", priority = 5, icon = "group",
    unlockLabel = "ui.career.delivery.parcelMods.large.unlockLabel",
    label = "ui.career.delivery.parcelMods.large.label",
    shortDescription = "ui.career.delivery.parcelMods.large.description",
    makeTemplate = typeTemplate("large"),
  },
  fluid = {
    unlockFlag = "logisticsFluidDelivery", priority = 6, icon = "droplet",
    unlockLabel = "ui.career.delivery.parcelMods.fluid.unlockLabel",
    label = "ui.career.delivery.parcelMods.fluid.label",
    shortDescription = "ui.career.delivery.parcelMods.fluid.description",
    makeTemplate = typeTemplate("fluid"),
  },
  dryBulk = {
    unlockFlag = "logisticsAggregateDelivery", priority = 6, icon = "rocks",
    unlockLabel = "ui.career.delivery.parcelMods.dryBulk.unlockLabel",
    label = "ui.career.delivery.parcelMods.dryBulk.label",
    shortDescription = "ui.career.delivery.parcelMods.dryBulk.description",
    makeTemplate = typeTemplate("dryBulk"),
  },
  cement = {
    unlockFlag = "logisticsCementDelivery", priority = 6, icon = "rocks",
    unlockLabel = "Cement", label = "Cement",
    shortDescription = "Requires a cement-capable container to transport.",
    makeTemplate = typeTemplate("cement"),
  },
  cash = {
    unlockFlag = "logisticsCashDelivery", priority = 6, icon = "beamCurrency",
    unlockLabel = "Cash", label = "Cash",
    shortDescription = "Requires a cash-capable container to transport.",
    makeTemplate = typeTemplate("cash"),
  },
  parcel = {
    unlockFlag = "smallPackagesDelivery", priority = 6, hidden = true, icon = "cardboardBox",
    unlockLabel = "ui.career.delivery.parcelMods.parcel.unlockLabel",
    label = "ui.career.delivery.parcelMods.parcel.label",
    shortDescription = "ui.career.delivery.parcelMods.parcel.description",
    makeTemplate = typeTemplate("parcel"),
  },
  slot32 = {
    unlockFlag = "logisticsParcel32Slots", priority = 6, hidden = true, icon = "cardboardBox",
    unlockLabel = "32 Slot Parcels", label = "32 Slot Parcels",
    shortDescription = "Allows handling parcels above 16 slots.",
    makeTemplate = typeTemplate("slot32"),
  },
  slot64 = {
    unlockFlag = "logisticsParcel64Slots", priority = 6, hidden = true, icon = "cardboardBox",
    unlockLabel = "64 Slot Parcels", label = "64 Slot Parcels",
    shortDescription = "Allows handling parcels above 32 slots.",
    makeTemplate = typeTemplate("slot64"),
  },
  slot128 = {
    unlockFlag = "logisticsParcel128Slots", priority = 6, hidden = true, icon = "cardboardBox",
    unlockLabel = "128 Slot Parcels", label = "128 Slot Parcels",
    shortDescription = "Allows handling parcels above 64 slots.",
    makeTemplate = typeTemplate("slot128"),
  },
  hazardous = {
    unlockFlag = "hazardousMaterialsDelivery", priority = 6, icon = "roadblockL",
    unlockLabel = "ui.career.delivery.parcelMods.hazardous.unlockLabel",
    label = "ui.career.delivery.parcelMods.hazardous.label",
    shortDescription = "ui.career.delivery.parcelMods.hazardous.description",
    makeTemplate = typeTemplate("hazardous"),
  },
  airExpress = {
    unlockFlag = "smallPackagesDelivery", priority = 2, important = true, icon = "cardboardBox",
    unlockLabel = "Air Express Parcels", label = "Air Parcel", shortDescription = "",
    makeTemplate = function(g, p, distance) return { type = "post", moneyMultipler = 40.0 } end,
  },
  remoteDelivery = {
    unlockFlag = "smallPackagesDelivery", priority = 2, important = true, icon = "cardboardBox",
    unlockLabel = "Remote Delivery Parcels", label = "Remote Parcel", shortDescription = "",
    makeTemplate = function(g, p, distance) return { type = "post", moneyMultipler = 15.0 } end,
  },
  pepperReduction = {
    unlockFlag = "smallPackagesDelivery", priority = 2, important = true, icon = "cardboardBox",
    unlockLabel = "Pepper Valley Frieght", label = "Remote Parcel", shortDescription = "",
    makeTemplate = function(g, p, distance) return { type = "post", moneyMultipler = 0.5 } end,
  },
}
-- Parcels at or above this many slots are large/heavy even without an authored modifier.
local largeSlotThreshold = 128

-- Missing definitions are reported once per key and level, regardless of how many parcels use the template.
local unknownModifiersByLevel = {}
local mapDefinitions, activeModifiers, activeMap

local function validateMapModifier(data)
  if data.version ~= 1 then return nil, "unsupported parcel modifier version" end
  if not catalog.validId(data.mapId) or not catalog.validId(data.key) then return nil, "invalid mapId or key" end
  for _, field in ipairs({"unlockFlag", "unlockLabel", "icon", "label"}) do
    if type(data[field]) ~= "string" or data[field] == "" then return nil, "missing " .. field end
  end
  if not catalog.finite(data.priority) then return nil, "invalid priority" end
  if type(data.template) ~= "table" or not catalog.validId(data.template.type) then return nil, "invalid template" end
  if data.template.type ~= data.key and not modifiers[data.template.type] then return nil, "unknown template type" end
  local multiplier = data.template.moneyMultipler
  if multiplier ~= nil and (not catalog.finite(multiplier) or multiplier <= 0) then return nil, "invalid pay multiplier" end
  return data
end

local function currentModifiers()
  local mapId = getCurrentLevelIdentifier and getCurrentLevelIdentifier()
  if not mapId then return modifiers end
  if activeModifiers and activeMap == mapId then return activeModifiers end
  mapDefinitions = mapDefinitions or catalog.scan("/gameplay/overhaul/logistics/parcelModifiers/", validateMapModifier, "parcelMods")
  activeMap, activeModifiers = mapId, {}
  for key, modifier in pairs(modifiers) do activeModifiers[key] = modifier end
  local seen = {}
  for _, definition in ipairs(mapDefinitions) do
    if definition.mapId == mapId then
      if seen[definition.key] then
        log("W", "parcelMods", "Ignoring duplicate map parcel modifier: " .. definition.id)
      else
        seen[definition.key] = true
        local modifier = deepcopy(definition)
        modifier.shortDescription = modifier.shortDescription or ""
        modifier.makeTemplate = function() return deepcopy(definition.template) end
        activeModifiers[definition.key] = modifier
      end
    end
  end
  return activeModifiers
end

-- Helpers -----------------------------------------------------------------------------------------

local function sortByPrio(a, b)
  local modifiers = currentModifiers()
  return modifiers[a.type].priority < modifiers[b.type].priority
end

local function isParcelModUnlocked(modKey, unlockedFlags)
  local modifiers = currentModifiers()
  if not modifiers[modKey] or not modifiers[modKey].unlockFlag then
    return false
  end
  if unlockedFlags then
    return unlockedFlags[modifiers[modKey].unlockFlag] or false
  end
  return true -- no flags = everything unlocked
end

-- Public API --------------------------------------------------------------------------------------

function M.calculateTimedModifierTime(distance)
  local r = math.random() + 1
  return (distance / 13) + (30 * r)
end

function M.generateModifiers(item, parcelTemplate, distance)
  local modifiers = currentModifiers()
  local mods = {}
  local hasLargeModifier = false
  math.randomseed(item.groupSeed)

  local r = math.random()
  for _, modKey in ipairs(tableKeysSorted(parcelTemplate.modChance or {})) do
    local modifier = modifiers[modKey]
    if not modifier then
      local level = getCurrentLevelIdentifier() or 'unknown'
      local warned = unknownModifiersByLevel[level] or {}
      unknownModifiersByLevel[level] = warned
      if not warned[modKey] then
        log('W', 'parcelMods', 'Skipping unknown parcel modifier "' .. modKey .. '" on "' .. level .. '"')
        warned[modKey] = true
      end
    elseif r <= parcelTemplate.modChance[modKey] then
      local modTemplate = modifier.makeTemplate(item.groupSeed, parcelTemplate, distance)
      table.insert(mods, modTemplate)
      hasLargeModifier = hasLargeModifier or modTemplate.type == "large"
    end
    r = math.random()
  end

  -- Physical kilograms are deliberately irrelevant here. Only 128-slot cargo (or an explicitly authored large modifier) is classified as large/heavy.
  if item.slots >= largeSlotThreshold and not hasLargeModifier then
    table.insert(mods, modifiers.large.makeTemplate())
  end

  -- Gate parcel size tiers by skill unlocks. Round slot values to avoid floating-point edge cases (32.000001).
  local slotCount = math.floor((item.slots or 0) + 0.5)
  if slotCount > 64 then
    table.insert(mods, modifiers.slot128.makeTemplate())
  elseif slotCount > 32 then
    table.insert(mods, modifiers.slot64.makeTemplate())
  elseif slotCount > 16 then
    table.insert(mods, modifiers.slot32.makeTemplate())
  end

  table.sort(mods, sortByPrio)
  return mods
end

M.isParcelModUnlocked = isParcelModUnlocked

-- Any locked mod in modKeys locks the parcel. Without unlockedFlags (non-career mode) nothing is locked. Returns whether it is locked, and the highest-level flag definition among the mods' unlock flags.
function M.lockedBecauseOfMods(modKeys, unlockedFlags, flagDefinitions, modifierDefinitions)
  local modData = modifierDefinitions or currentModifiers()
  local locked = false
  local definitions = {}
  for key, _ in pairs(modKeys) do
    if modData[key] and modData[key].unlockFlag then
      local unlockFlag = modData[key].unlockFlag
      if flagDefinitions then
        local flagDef = flagDefinitions[unlockFlag]
        if flagDef then
          table.insert(definitions, flagDef)
        end
      end
      if unlockedFlags and not unlockedFlags[unlockFlag] then
        locked = true
      end
    end
  end
  table.sort(definitions, function(a, b)
    return (a and a.level or 0) > (b and b.level or 0)
  end)
  return locked, definitions[1]
end

-- Unlock status for every modifier. Without unlockedFlags, all modifiers count as unlocked.
function M.getParcelModUnlockStatusSimple(unlockedFlags)
  local modifiers = currentModifiers()
  local status = {}
  for modKey in pairs(modifiers) do
    status[modKey] = isParcelModUnlocked(modKey, unlockedFlags)
  end
  return status
end

local requiredModifierFields = {
  { "makeTemplate", "function" }, { "unlockFlag", "string" }, { "unlockLabel", "string" },
  { "priority", "number" }, { "icon", "string" }, { "label", "string" },
}

function M.addModifier(key, mod)
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

  for _, field in ipairs(requiredModifierFields) do
    local name, expected = field[1], field[2]
    if type(mod[name]) ~= expected then
      log("E", "parcelMods", "addModifier: Modifier '" .. key .. "' missing required '" .. name .. "' " .. expected)
      return false
    end
  end

  modifiers[key] = mod
  activeModifiers = nil

  log("I", "parcelMods", "addModifier: Successfully added modifier '" .. key .. "'")
  return true
end

function M.getModData(key)
  local modifier = currentModifiers()[key]
  if not modifier then return nil end
  local data = {}
  for field, value in pairs(modifier) do
    data[field] = value
  end
  data.unlockLabel = _tr(data.unlockLabel)
  data.label = _tr(data.label)
  data.shortDescription = data.shortDescription ~= "" and _tr(data.shortDescription) or ""
  return data
end

function M.getModifierIcon(key)
  return currentModifiers()[key].icon
end

function M.getLabelAndShortDescription(key)
  local modifier = currentModifiers()[key]
  return _tr(modifier.label), modifier.shortDescription ~= "" and _tr(modifier.shortDescription) or ""
end

function M.isImportant(key)
  return currentModifiers()[key].important or false
end

function M.getParcelModProgressLabel(key)
  return _tr(currentModifiers()[key].unlockLabel)
end

function M.getModifiers()
  return currentModifiers()
end

function M.getModifierKeys(item)
  local keys = {}
  for _, mod in ipairs((item and item.modifiers) or {}) do
    if mod.type then keys[mod.type] = true end
  end
  return keys
end

function M.hasModifier(item, modifierType)
  if not item or not modifierType then return false end
  for _, mod in ipairs(item.modifiers or {}) do
    if mod.type == modifierType then return true end
  end
  return false
end

return M
