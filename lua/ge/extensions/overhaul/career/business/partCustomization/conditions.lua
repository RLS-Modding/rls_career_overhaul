-- Paid mechanical conditions survive replacements; only installed instances receive their own conditions.
-- Read live capture, candidate projection, native initialization, then the returned API.
local installer = {}

function installer.new(inputs)
  local parts = inputs.parts

  local function capture(session, onDone)
    if session and not session.saveHold then
      session.saveHold = require('overhaul/lib/save/store').hold(inputs.owner, 'business preview', {stage = 'beforeRecovery'})
    end
    if not session or session.conditionsCaptured or not session.isPersonal or not session.inventoryId then
      onDone(true); return
    end
    local obj = parts.baseline.getBusinessVehicleObject(session.businessId, session.vehicleId)
    if not obj then onDone(false); return end
    local inventoryOwner = overhaul_career_garage_inventory
    local inventory = inventoryOwner.getVehicles()
    local inventoryRecord = inventory and inventory[session.inventoryId]
    local vehicle = parts.preview.getPersonalVehicleData(session.vehicleId, session.businessId)
    core_vehicleBridge.requestValue(obj, function(res)
      local currentInventory = inventoryOwner.getVehicles()
      if not inputs.isOwnerCurrent() or inputs.runtime.currentSession ~= session
        or overhaul_career_garage_inventory ~= inventoryOwner or not inventoryRecord
        or not currentInventory or currentInventory[session.inventoryId] ~= inventoryRecord
        or parts.preview.getPersonalVehicleData(session.vehicleId, session.businessId) ~= vehicle then
        onDone(false); return
      end
      if not res or type(res.result) ~= 'table' then onDone(false); return end
      if overhaul_career_market_valueCalculator.getNumberOfBrokenParts(res.result) > 0 then onDone(false); return end
      -- The bound car can have newer wear than its last inventory save.
      session.initial.partConditions = deepcopy(res.result)
      session.preview.partConditions = deepcopy(res.result)
      session.conditionsCaptured = true
      -- This is observed paid wear, so saving during a preview must not retain an older healthy record.
      if vehicle then vehicle.partConditions = deepcopy(res.result) end
      inventoryRecord.partConditions = deepcopy(res.result)
      inventoryOwner.setVehicleDirty(session.inventoryId)
      onDone(true)
    end, 'getPartConditions')
  end

  local function forConfig(session, config)
    local baseline = session.initial.partList or parts.baseline.flattenPartsTree(session.initial.config.partsTree or {})
    local candidate = parts.baseline.flattenPartsTree(config.partsTree or {})
    local changed = {}
    for slot, name in pairs(baseline) do
      if candidate[slot] ~= name then changed[slot] = true end
    end
    for _, part in ipairs(session.replacementParts or {}) do
      if part.slotPath then changed[part.slotPath] = true end
    end
    local conditions = deepcopy(session.initial.partConditions or {})
    for key in pairs(conditions) do
      for root in pairs(changed) do
        if key:sub(1, #root) == root then conditions[key] = nil; break end
      end
    end
    for _, part in ipairs(session.replacementParts or {}) do
      if part.slotPath and part.partName and part.partName ~= '' and candidate[part.slotPath] == part.partName then
        local stored
        if part.fromInventory and overhaul_career_business_partInventory then
          local inventory = overhaul_career_business_partInventory.getInventory()
          local owned = inventory and inventory[part.partId]
          if owned and owned.name == part.partName and tostring(owned.businessId) == tostring(session.businessId) then
            stored = owned.partCondition
          end
        end
        conditions[part.slotPath .. part.partName] = deepcopy(stored or {integrityValue = 1, visualValue = 1, odometer = 0})
      end
    end
    return require('overhaul/lib/business/partConditions').sanitizePartConditions(conditions,
      parts.preview.getPartConditionApplyOpts(config))
  end

  local function apply(session, vehObj, config)
    return require('overhaul/lib/business/partConditions').applyInitPartConditions(vehObj,
      forConfig(session, config), nil, nil, nil, parts.preview.getPartConditionApplyOpts(config))
  end

  local function captureCurrentBuild(session)
    if session.isPersonal and session.inventoryId then
      local obj = parts.baseline.getBusinessVehicleObject(session.businessId, session.vehicleId)
      local inventory = overhaul_career_garage_inventory
      if not obj or inventory.getInventoryIdFromVehicleId(obj:getID()) ~= session.inventoryId then return false end
      overhaul_career_repair_damageManager.saveDamageState(session.inventoryId)
    end
    return true
  end

  local function release(session)
    if session.saveHold then session.saveHold.release(); session.saveHold = nil end
  end

  return {capture = capture, forConfig = forConfig, apply = apply, captureCurrentBuild = captureCurrentBuild, release = release}
end

return installer
