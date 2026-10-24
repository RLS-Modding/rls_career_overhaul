-- Finite damage: inspect soft wear and faults, quote selected work and apply repairs.
-- Map: Constants; Small helpers; Integrity state; Pricing; Healing a broken part; Assessment lines; Assessment; Quoting; Applying.

-- Garage eligibility keeps stock broken-part rules; roadside selection uses this separate assessment.

local M = {}

-- Constants ---------------------------------------------------------------------------------------

-- Soft integrity only when clearly below perfect (avoids float noise).
local SOFT_INTEGRITY_THRESHOLD = 0.97
local SOFT_INTEGRITY_MIN = 15
local SOFT_INTEGRITY_MAX = 80
-- Worn tires: only call out when under half life (0.9 gave false positives on nearly-new tires).
local WORN_TIRE_REMAINING = 0.5
local WORN_TIRE_MIN = 10
local WORN_TIRE_MAX = 40
-- Bent or deformed mesh with integrity still above 0 (paint fade from mileage does not count).
local COSMETIC_DEFORM_FEE = 35
local INTEGRITY_STATE_FEE = 45
local FLAT_TIRE_FEE = 60
local FINITE_MINIMUM = 40
-- BeamNG dumps powertrain integrityState (damageFrictionCoef=1, isBroken=false, ...) even on healthy parts.
local HEALTHY_DAMAGE_COEF = 1
local COEF_EPS = 0.000001
local FALLING_DAMAGE_COEFS = {
  damagelocktorquecoef = true,
  damagelockupclutchtorquecoef = true,
  damagegearratiochangeratecoef = true,
  damageviscoustorquecoef = true,
  damageexhaustpowercoef = true,
}

-- Small helpers -----------------------------------------------------------------------------------

local function getVehicle(inventoryId)
  inventoryId = tonumber(inventoryId)
  if not inventoryId then
    return nil, nil
  end
  local vehicles = overhaul_career_garage_inventory.getVehicles() or {}
  return vehicles[inventoryId], inventoryId
end

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

local function roundMoney(n)
  return math.floor((tonumber(n) or 0) + 0.5)
end

local function shortPartPath(partPath)
  if type(partPath) ~= "string" or partPath == "" then
    return "Unknown part"
  end
  local leaf = partPath:match("([^/\\]+)$")
  return leaf or partPath
end

local function makeLine(kind, label, detail, cost, meta)
  meta = meta or {}
  local selectable = meta.selectable
  if selectable == nil then
    selectable = kind ~= "info"
  end
  return {
    id = meta.id,
    kind = kind,
    label = label,
    detail = detail,
    cost = roundMoney(cost),
    selectable = selectable == true,
    partPath = meta.partPath,
    partSlotPath = meta.partSlotPath,
    wheelName = meta.wheelName,
  }
end

-- Integrity state ---------------------------------------------------------------------------------

-- Lists the real faults in an integrityState table; returns false and nil when the state is healthy.
local function integrityStateNeedsAttention(integrityState, scanNested, parentKey)
  if type(integrityState) ~= "table" then
    return false, nil
  end

  local issues = {}

  local function add(msg)
    table.insert(issues, msg)
  end

  if integrityState.isBroken == true then
    add("isBroken")
  end
  if integrityState.clutchPermanentlyDamaged == true then
    add("clutchPermanentlyDamaged")
  end

  for key, value in pairs(integrityState) do
    if key == "energyStorage" then
      -- Fuel / battery fill level is not repair damage.
    elseif type(value) == "table" and (key == "powertrain" or key == "synchroWear" or key == "thermals" or scanNested) then
      -- Stock groups by device; legacy device states can put thermals at the root.
      local needsAttention, detail = integrityStateNeedsAttention(value, true, key)
      if needsAttention then add(tostring(key) .. ": " .. detail) end
    elseif type(value) == "number" then
      local lower = string.lower(tostring(key))
      if (parentKey == "synchroWear" or lower == "synchrowear" or lower == "radiatordamage") and value > 0 then
        -- Synchros are zero-based wear, indexed by gear (including reverse).
        add(string.format("%s=%.3f", tostring(key), value))
      elseif lower:find("leak", 1, true) and value > 0 then
        add(string.format("%s=%.3f", key, value))
      elseif lower:find("chance", 1, true) and value > 0.01 then
        add(string.format("%s=%.3f", key, value))
      elseif lower:find("damage", 1, true) or lower:find("wear", 1, true) then
        -- Stock torque/shift coefficients fall; clutch free play and friction rise.
        if FALLING_DAMAGE_COEFS[lower] then
          if value < HEALTHY_DAMAGE_COEF - COEF_EPS then
            add(string.format("%s=%.3f", key, value))
          end
        elseif value > HEALTHY_DAMAGE_COEF + COEF_EPS then
          add(string.format("%s=%.3f", key, value))
        end
      end
    elseif type(value) == "boolean" and value == true and key ~= "isBroken" and key ~= "clutchPermanentlyDamaged" then
      -- Ignore unknown false flags; only true bools beyond the known ones.
      if string.lower(tostring(key)):find("broken", 1, true)
        or string.lower(tostring(key)):find("damage", 1, true)
        or string.lower(tostring(key)):find("fail", 1, true) then
        add(tostring(key))
      end
    end
  end

  if #issues == 0 then
    return false, nil
  end
  table.sort(issues)
  return true, table.concat(issues, ", ")
end

local clearIntegrityStateKeepFuel = require('overhaul/lib/parts/repairCondition').clearIntegrityStateKeepFuel

-- Pricing -----------------------------------------------------------------------------------------

local function partMarketMultiplier()
  return overhaul_career_market_valueCalculator.getPartMarketMultiplier() or 1
end

local function brokenReplacePrice(part)
  local price = (part and part.value or 700) * partMarketMultiplier()
  if overhaul_career_economy_difficultyMode.isHardcoreMode() then
    return math.floor(price * 1.25 * 100) / 100
  end
  return math.floor(price * 0.9 * 100) / 100
end

-- Healing a broken part -------------------------------------------------------------------------

-- Counts the repair on the inventory part and marks its slot changed.
local function bumpBrokenPartRepairCount(inventoryId, partSlotPath, partPath)
  local inventoryPart = nil
  if partSlotPath then
    inventoryPart = overhaul_career_parts_partInventory.getPart(inventoryId, partSlotPath)
  end
  if not inventoryPart and partPath then
    local map = overhaul_career_parts_partInventory.getPartPathToPartIdMap()
    local partId = map and map[inventoryId] and map[inventoryId][partPath]
    local inv = overhaul_career_parts_partInventory.getInventory()
    inventoryPart = partId and inv and inv[partId] or nil
  end
  if not inventoryPart then
    return
  end
  inventoryPart.repairCount = (inventoryPart.repairCount or 0) + 1
  local vehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  if vehicle and inventoryPart.containingSlot then
    vehicle.changedSlots = vehicle.changedSlots or {}
    vehicle.changedSlots[inventoryPart.containingSlot] = true
  end
end

-- Resets a fully broken part to integrity 1; the paint and odometer fade survive the repair.
local function healBrokenPart(vehicle, inventoryId, partPath, partSlotPath)
  local info = vehicle.partConditions and vehicle.partConditions[partPath]
  if type(info) ~= "table" or tonumber(info.integrityValue) ~= 0 then
    return false
  end
  bumpBrokenPartRepairCount(inventoryId, partSlotPath, partPath)
  if info.visualState and info.visualState.paint and info.visualState.paint.originalPaints then
    info.visualState = {
      paint = {
        originalPaints = info.visualState.paint.originalPaints,
        odometer = 0,
      },
    }
  else
    info.visualState = nil
  end
  info.visualValue = 1
  clearIntegrityStateKeepFuel(info)
  info.integrityValue = 1
  return true
end

local function healAllBrokenParts(vehicle, inventoryId)
  local n = 0
  if type(vehicle.partConditions) ~= "table" then
    return n
  end
  for partPath, info in pairs(vehicle.partConditions) do
    if type(info) == "table" and tonumber(info.integrityValue) == 0 then
      if healBrokenPart(vehicle, inventoryId, partPath, nil) then
        n = n + 1
      end
    end
  end
  return n
end

-- Assessment lines --------------------------------------------------------------------------------

-- One "Replace" line per fully broken part found by walking the parts tree.
local function collectBrokenReplaceLines(vehicle, inventoryId, lines)
  local brokenParts = 0
  local brokenPartsCost = 0
  if type(vehicle.partConditions) ~= "table" or type(vehicle.config) ~= "table" or not vehicle.config.partsTree then
    return brokenParts, brokenPartsCost
  end

  local function traverse(node)
    if not node or not node.partPath then return end
    local partCondition = vehicle.partConditions[node.partPath]
    if partCondition and partCondition.integrityValue and partCondition.integrityValue == 0 then
      brokenParts = brokenParts + 1
      local part = nil
      if node.path then
        part = overhaul_career_parts_partInventory.getPart(inventoryId, node.path)
      end
      local price = brokenReplacePrice(part)
      brokenPartsCost = brokenPartsCost + price
      local label = (part and (part.niceName or part.name)) or shortPartPath(node.partPath)
      table.insert(lines, makeLine(
        "broken",
        "Replace: " .. tostring(label),
        "Fully broken (integrity 0)",
        price,
        {
          id = "broken:" .. tostring(node.partPath),
          partPath = node.partPath,
          partSlotPath = node.path,
        }
      ))
    end
    if node.children then
      for _, child in pairs(node.children) do
        traverse(child)
      end
    end
  end

  traverse(vehicle.config.partsTree)
  return brokenParts, brokenPartsCost
end

-- Fallback when the parts tree finds nothing but the condition dictionary still has broken parts. Priced through the repair details; returns nil when that gives no usable price.
local function collectDictionaryBrokenLine(vehicle, lines)
  local dictBroken = overhaul_career_market_valueCalculator.getNumberOfBrokenParts(vehicle.partConditions) or 0
  if dictBroken <= 0 then
    return nil
  end
  local ok, details = pcall(overhaul_career_market_valueCalculator.getRepairDetails, vehicle)
  if not ok or type(details) ~= "table" then
    return nil
  end
  local brokenParts = tonumber(details.partsCountToBeReplaced) or dictBroken
  local brokenPartsCost = tonumber(details.price) or 0
  table.insert(lines, makeLine(
    "broken",
    string.format("Replace %d fully broken part(s)", brokenParts),
    "Priced via repair details (no part names available)",
    brokenPartsCost,
    {id = "broken:all"}
  ))
  return brokenParts, brokenPartsCost
end

local function newFiniteTotals()
  return {softN = 0, cosmeticN = 0, stateN = 0, softCost = 0, cosmeticCost = 0, stateCost = 0}
end

-- Soft integrity: a part below the threshold but not broken.
local function addSoftIntegrityLine(totals, lines, partPath, label, integrity)
  totals.softN = totals.softN + 1
  local severity = 1 - integrity
  local cost = clamp(SOFT_INTEGRITY_MIN + severity * (SOFT_INTEGRITY_MAX - SOFT_INTEGRITY_MIN), SOFT_INTEGRITY_MIN, SOFT_INTEGRITY_MAX)
  totals.softCost = totals.softCost + cost
  table.insert(lines, makeLine(
    "soft",
    "Repair: " .. label,
    string.format("Soft damage (integrity %.0f%%)", integrity * 100),
    cost,
    {id = "soft:" .. partPath, partPath = partPath}
  ))
end

-- Cosmetics: charged for mesh deformation only, while the part still has integrity. visualValue is not used: career trucks get about 0.8 from odometer paint fade and look fine. Fully broken parts are covered by the replace line.
local function addCosmeticLine(totals, lines, partPath, label, info, integrity)
  local vs = info.visualState
  if type(vs) ~= "table" or vs.jbeam == nil or integrity == nil or integrity <= 0 then
    return
  end
  totals.cosmeticN = totals.cosmeticN + 1
  totals.cosmeticCost = totals.cosmeticCost + COSMETIC_DEFORM_FEE
  table.insert(lines, makeLine(
    "cosmetic",
    "Straighten: " .. label,
    "Bent / deformed mesh",
    COSMETIC_DEFORM_FEE,
    {id = "cosmetic:" .. partPath, partPath = partPath}
  ))
end

-- integrityState alone is usually a healthy powertrain dump, so it counts only where integrity is fine.
local function addStateFaultLine(totals, lines, partPath, label, info, integrity)
  local needsState, stateKeys = integrityStateNeedsAttention(info.integrityState)
  if not needsState or (integrity ~= nil and integrity < SOFT_INTEGRITY_THRESHOLD) then
    return
  end
  totals.stateN = totals.stateN + 1
  totals.stateCost = totals.stateCost + INTEGRITY_STATE_FEE
  table.insert(lines, makeLine(
    "state",
    "Fault: " .. label,
    "State: " .. (stateKeys or "unknown"),
    INTEGRITY_STATE_FEE,
    {id = "state:" .. partPath, partPath = partPath}
  ))
end

-- Soft, cosmetic and state lines for every part, in sorted path order.
local function collectFinitePartLines(partConditions, lines)
  local totals = newFiniteTotals()
  if type(partConditions) ~= "table" then
    return totals
  end

  local paths = {}
  for partPath, _ in pairs(partConditions) do
    table.insert(paths, partPath)
  end
  table.sort(paths)

  for _, partPath in ipairs(paths) do
    local info = partConditions[partPath]
    if type(info) == "table" then
      local label = shortPartPath(partPath)
      local integrity = tonumber(info.integrityValue)
      if integrity ~= nil and integrity > 0 and integrity < SOFT_INTEGRITY_THRESHOLD then
        addSoftIntegrityLine(totals, lines, partPath, label, integrity)
      end
      addCosmeticLine(totals, lines, partPath, label, info, integrity)
      addStateFaultLine(totals, lines, partPath, label, info, integrity)
    end
  end

  return totals
end

-- Flat tires cost a fixed fee; worn tires cost more the less tread they have left.
local function collectTireLines(vehicle, lines)
  local flats, worn, tireCost = 0, 0, 0
  local layout = vehicle and vehicle.rlsTireLayout
  local wheels = layout and layout.wheels
  if type(wheels) ~= "table" then
    return flats, worn, tireCost
  end

  for _, wheel in ipairs(wheels) do
    if type(wheel) == "table" then
      local name = tostring(wheel.name or "tire")
      if wheel.flat == true then
        flats = flats + 1
        tireCost = tireCost + FLAT_TIRE_FEE
        table.insert(lines, makeLine(
          "tire",
          "Flat tire: " .. name,
          "Needs inflate / replace",
          FLAT_TIRE_FEE,
          {id = "tire:" .. name, wheelName = name}
        ))
      else
        local remaining = tonumber(wheel.remaining)
        if remaining ~= nil and remaining < WORN_TIRE_REMAINING then
          worn = worn + 1
          local severity = 1 - clamp(remaining, 0, 1)
          local cost = clamp(WORN_TIRE_MIN + severity * (WORN_TIRE_MAX - WORN_TIRE_MIN), WORN_TIRE_MIN, WORN_TIRE_MAX)
          tireCost = tireCost + cost
          table.insert(lines, makeLine(
            "tire",
            "Worn tire: " .. name,
            string.format("%.0f%% remaining", remaining * 100),
            cost,
            {id = "tire:" .. name, wheelName = name}
          ))
        end
      end
    end
  end

  return flats, worn, tireCost
end

local function ensureTireSystem()
  if not overhaul_career_maintenance_tireSystem then
    extensions.load("overhaul_career_maintenance_tireSystem")
  end
  return overhaul_career_maintenance_tireSystem
end

-- Turns a selection (a list of ids, or a map of ids) into a set.
local function toIdSet(selectedIds)
  local set = {}
  if type(selectedIds) ~= "table" then
    return set
  end
  for _, id in ipairs(selectedIds) do
    if type(id) == "string" and id ~= "" then
      set[id] = true
    end
  end
  -- Also accept map-style { [id] = true } from some Lua bridges.
  for key, value in pairs(selectedIds) do
    if type(key) == "string" and value then
      set[key] = true
    end
  end
  return set
end

-- Assessment --------------------------------------------------------------------------------------

-- The minimum service charge is added as its own line, so the total never falls below it.
local function applyMinimumServiceCharge(hasFinite, finiteSum, lines)
  if not hasFinite or finiteSum >= FINITE_MINIMUM then
    return finiteSum
  end
  local bump = FINITE_MINIMUM - finiteSum
  table.insert(lines, makeLine(
    "info",
    "Minimum service charge",
    "Applied when any soft/cosmetic/tire work is selected",
    bump,
    {id = "info:minimum", selectable = false}
  ))
  return FINITE_MINIMUM
end

local function missingAssessment()
  return {
    ok = false,
    hasDamage = false,
    hasBrokenParts = false,
    hasFiniteDamage = false,
    hasTireDamage = false,
    brokenParts = 0,
    brokenPartsCost = 0,
    finiteCost = 0,
    totalPreLabor = 0,
    lines = {},
    reason = "Vehicle not found.",
  }
end

-- Assesses finite and broken damage for roadside repair quoting. Lines are fully enumerated (no truncation); the UI shows them with "Show more" and selection. @return table assessment, including `lines` for the UI selection
function M.assess(inventoryId)
  local vehicle, id = getVehicle(inventoryId)
  if not vehicle then
    return missingAssessment()
  end

  local lines = {}
  local brokenParts, brokenPartsCost = collectBrokenReplaceLines(vehicle, id, lines)
  if brokenParts == 0 then
    local fallbackParts, fallbackCost = collectDictionaryBrokenLine(vehicle, lines)
    if fallbackParts then
      brokenParts, brokenPartsCost = fallbackParts, fallbackCost
    end
  end

  local totals = collectFinitePartLines(vehicle.partConditions, lines)
  local flats, worn, tireCost = collectTireLines(vehicle, lines)
  local finiteSum = totals.softCost + totals.cosmeticCost + totals.stateCost + tireCost
  local hasFinite = (totals.softN + totals.cosmeticN + totals.stateN + flats + worn) > 0
  finiteSum = applyMinimumServiceCharge(hasFinite, finiteSum, lines)

  local hasBroken = brokenParts > 0
  local hasDamage = hasBroken or hasFinite

  -- Only a clean vehicle has a reason: callers show it as the refusal for a repair.
  local reason
  if hasDamage then
    reason = nil
  else
    reason = "No damage to repair."
  end

  return {
    ok = true,
    hasDamage = hasDamage,
    hasBrokenParts = hasBroken,
    hasFiniteDamage = hasFinite,
    hasTireDamage = (flats + worn) > 0,
    brokenParts = brokenParts,
    softIntegrityParts = totals.softN,
    cosmeticParts = totals.cosmeticN,
    stateFaultParts = totals.stateN,
    flatTires = flats,
    wornTires = worn,
    brokenPartsCost = roundMoney(brokenPartsCost),
    finiteCost = roundMoney(finiteSum),
    softCost = roundMoney(totals.softCost),
    cosmeticCost = roundMoney(totals.cosmeticCost),
    stateCost = roundMoney(totals.stateCost),
    tireCost = roundMoney(tireCost),
    totalPreLabor = roundMoney(brokenPartsCost + finiteSum),
    finiteMinimum = FINITE_MINIMUM,
    lines = lines,
    reason = reason,
  }
end

-- Quoting -----------------------------------------------------------------------------------------

-- A refused quote has the same shape as a priced one, with no lines and a reason.
local function refusedQuote(message)
  return {
    ok = false,
    message = message,
    selectedLines = {},
    brokenPartsCost = 0,
    finiteCost = 0,
    totalPreLabor = 0,
    hasBrokenParts = false,
    hasFiniteDamage = false,
    hasTireDamage = false,
    selectedCount = 0,
  }
end

-- Empty selection means nothing to do (the UI blocks it). Nil means every selectable line.
local function selectionIdSet(assessment, selectedIds)
  local idSet = toIdSet(selectedIds)
  if selectedIds == nil then
    for _, line in ipairs(assessment.lines or {}) do
      if line.selectable and line.id then
        idSet[line.id] = true
      end
    end
  end
  return idSet
end

-- Collects the chosen lines and sums their costs by family (broken parts, finite work, tires).
local function tallySelectedLines(assessment, idSet)
  local selectedLines = {}
  local tally = {brokenPartsCost = 0, finiteRaw = 0, hasBroken = false, hasFinite = false, hasTire = false}
  for _, line in ipairs(assessment.lines or {}) do
    if line.selectable and line.id and idSet[line.id] then
      table.insert(selectedLines, line)
      if line.kind == "broken" then
        tally.brokenPartsCost = tally.brokenPartsCost + (tonumber(line.cost) or 0)
        tally.hasBroken = true
      elseif line.kind == "tire" then
        tally.finiteRaw = tally.finiteRaw + (tonumber(line.cost) or 0)
        tally.hasFinite = true
        tally.hasTire = true
      elseif line.kind ~= "info" then
        tally.finiteRaw = tally.finiteRaw + (tonumber(line.cost) or 0)
        tally.hasFinite = true
      end
    end
  end
  return selectedLines, tally
end

--- Quotes a subset of damage lines (pre-labor). Re-assesses so prices stay current.
function M.quoteSelection(inventoryId, selectedIds)
  local assessment = M.assess(inventoryId)
  if not assessment.ok or not assessment.hasDamage then
    return refusedQuote(assessment.reason or "No damage to repair.")
  end

  local selectedLines, tally = tallySelectedLines(assessment, selectionIdSet(assessment, selectedIds))
  if #selectedLines == 0 then
    return refusedQuote("Select at least one item to repair.")
  end

  local finiteCost = tally.finiteRaw
  local minimumApplied = 0
  if tally.hasFinite and finiteCost < FINITE_MINIMUM then
    minimumApplied = FINITE_MINIMUM - finiteCost
    finiteCost = FINITE_MINIMUM
  end

  return {
    ok = true,
    selectedLines = selectedLines,
    selectedCount = #selectedLines,
    brokenPartsCost = roundMoney(tally.brokenPartsCost),
    finiteCost = roundMoney(finiteCost),
    finiteRaw = roundMoney(tally.finiteRaw),
    minimumApplied = roundMoney(minimumApplied),
    totalPreLabor = roundMoney(tally.brokenPartsCost + finiteCost),
    hasBrokenParts = tally.hasBroken,
    hasFiniteDamage = tally.hasFinite,
    hasTireDamage = tally.hasTire,
  }
end

-- Applying ----------------------------------------------------------------------------------------

-- Clears the deformation mesh damage and keeps the paint and odometer fade.
local function clearCosmeticDamage(info)
  local vs = info.visualState
  if type(vs) ~= "table" or vs.jbeam == nil then
    return false
  end
  vs.jbeam = nil
  if vs.paint then
    info.visualState = {paint = vs.paint}
  else
    info.visualState = nil
  end
  return true
end

-- Brings a part with soft integrity back to full integrity and clears its state faults.
local function healSoftIntegrity(info)
  local integrity = tonumber(info.integrityValue)
  if integrity == nil or integrity <= 0 or integrity >= SOFT_INTEGRITY_THRESHOLD then
    return false
  end
  info.integrityValue = 1
  clearIntegrityStateKeepFuel(info)
  return true
end

local function clearStateFault(info)
  local needs = integrityStateNeedsAttention(info.integrityState)
  if not needs then
    return false
  end
  clearIntegrityStateKeepFuel(info)
  info.integrityValue = 1
  return true
end

-- Applies one selected line; returns true when the line changed the vehicle.
local function applySelectedLine(vehicle, inventoryId, line)
  if not line or not line.kind then
    return false
  end

  if line.kind == "broken" then
    if line.id == "broken:all" or not line.partPath then
      return healAllBrokenParts(vehicle, inventoryId) > 0
    end
    return healBrokenPart(vehicle, inventoryId, line.partPath, line.partSlotPath)
  end

  -- Tires are applied in bulk after the loop.
  if line.kind == "tire" then
    return line.wheelName ~= nil
  end

  if not line.partPath then
    return false
  end
  local info = vehicle.partConditions and vehicle.partConditions[line.partPath]
  if type(info) ~= "table" then
    return false
  end
  if line.kind == "soft" then
    return healSoftIntegrity(info)
  elseif line.kind == "cosmetic" then
    return clearCosmeticDamage(info)
  elseif line.kind == "state" then
    return clearStateFault(info)
  end
  return false
end

-- Applies every quoted line; tire lines are collected by wheel for the bulk tire fix.
local function applyQuotedLines(vehicle, inventoryId, quote)
  local applied = 0
  local failedLines = {}
  local wheelNames = {}
  local repairedStructure = false
  for _, line in ipairs(quote.selectedLines) do
    if line.kind == "tire" and line.wheelName then
      wheelNames[line.wheelName] = true
    elseif applySelectedLine(vehicle, inventoryId, line) then
      applied = applied + 1
      if line.kind == "broken" or line.kind == "cosmetic" then repairedStructure = true end
    else
      table.insert(failedLines, line)
    end
  end
  return applied, failedLines, wheelNames, repairedStructure
end

-- Refreshes the chosen wheels; a refused fix makes every tire line a failed line.
local function applyTireWheels(inventoryId, quote, wheelNames, failedLines, deferRefresh)
  local tires = ensureTireSystem()
  local tireFixed = tires.forceFreshWheels(inventoryId, wheelNames, deferRefresh) and true or false
  if not tireFixed then
    for _, line in ipairs(quote.selectedLines) do
      if line.kind == "tire" then
        table.insert(failedLines, line)
      end
    end
  end
  return tireFixed
end

--- Applies only the selected damage lines, then refreshes tires and the vehicle as needed.
function M.applySelection(inventoryId, selectedIds, authorize)
  inventoryId = tonumber(inventoryId)
  local vehicle = getVehicle(inventoryId)
  if not vehicle then
    return {ok = false, message = "Vehicle not found."}
  end

  local quote = M.quoteSelection(inventoryId, selectedIds)
  if not quote.ok then
    return quote
  end

  -- Snapshot publication can refuse the work. Keep all record and part stores
  -- reversible, and send no live tyre commands until that boundary accepts it.
  local originals = {}
  if authorize then
    originals[vehicle] = deepcopy(vehicle)
    for _, part in pairs(overhaul_career_parts_partInventory.getInventory() or {}) do
      if type(part) == 'table' and tonumber(part.location) == inventoryId then
        originals[part] = deepcopy(part)
      end
    end
  end
  local function rollback()
    for target, original in pairs(originals) do
      table.clear(target)
      for key, value in pairs(original) do target[key] = value end
    end
  end
  local applied, failedLines, wheelNames, repairedStructure, tireFixed
  local prepared, result = pcall(function()
    applied, failedLines, wheelNames, repairedStructure = applyQuotedLines(vehicle, inventoryId, quote)
    tireFixed = false
    if next(wheelNames) then
      tireFixed = applyTireWheels(inventoryId, quote, wheelNames, failedLines, authorize ~= nil)
      if tireFixed then applied = applied + 1 end
    end
    if applied <= 0 then return false end
    return not authorize or authorize({ok = true, quote = quote, failedLines = failedLines}) == true
  end)
  if not prepared or not result then
    rollback()
    return {ok = false, message = prepared and 'Could not prepare selected repairs.' or tostring(result)}
  end

  if authorize and tireFixed then ensureTireSystem().refreshLiveTires(inventoryId) end

  overhaul_career_garage_inventory.setVehicleDirty(inventoryId)

  -- Tires and mechanical faults do not authorize straightening a saved body dent.
  local post = M.assess(inventoryId)
  if repairedStructure and not post.hasBrokenParts then
    overhaul_career_repair_damageManager.clearDamageState(inventoryId)
  end

  return {
    ok = true,
    applied = applied,
    tireFixed = tireFixed,
    quote = quote,
    failedLines = failedLines,
    remainingDamage = post.hasDamage == true,
  }
end

--- Inflates or refreshes tires after a roadside finite repair (works with maintenance mode off).
function M.applyTireFix(inventoryId)
  inventoryId = tonumber(inventoryId)
  if not inventoryId then
    return false
  end
  local assessment = M.assess(inventoryId)
  if not assessment.hasTireDamage then
    return false
  end
  local tires = ensureTireSystem()
  if tires and tires.forceFreshForVehicle then
    return tires.forceFreshForVehicle(inventoryId) and true or false
  end
  return false
end

function M.hasRepairableDamage(inventoryId)
  local a = M.assess(inventoryId)
  return a.hasDamage == true
end

return M
