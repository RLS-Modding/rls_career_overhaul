-- Fleet access for dyno sessions; dynoSession.lua owns the session and fleet/condition.lua replaces vehicles.
-- Cached records belong to this load and stay valid while their fleet record remains current; reset retires them.
local M = {}
local metadata = require('overhaul/lib/finance/metadata')
local vehicleCommands = require('overhaul/lib/vehicles/vehicleCommands')

function M.create(inputs)
  local owners, transient, generations = {}, {}, {}
  local retired = false
  local api = {}
  local function inventory() return overhaul_career_garage_inventory end
  local function fleet() return overhaul_career_business_fleet end
  local function businessKey(id) return type(id) == 'string' and id:sub(1, 9) == 'business_' end
  local function current(owner)
    return not retired and owner and owners[owner.key] == owner and fleet()
      and fleet().getVehicleById(owner.businessId, owner.vehicleId) == owner.record
  end
  local function authorized(owner)
    return current(owner) and overhaul_career_business_manager.isPurchasedBusiness('racingTeam', owner.businessId) == true
  end
  local function resolve(vehId)
    local personalId = inventory().getInventoryIdFromVehicleId(vehId)
    if personalId and not businessKey(personalId) and inventory().getVehicles()[personalId] then return personalId end
    local vehicles = fleet()
    if retired or not vehicles or not vehicles.getBusinessVehicleFromSpawnedId then return nil end
    local businessId, vehicleId = vehicles.getBusinessVehicleFromSpawnedId(vehId)
    if not businessId or not vehicleId or not overhaul_career_business_manager.isPurchasedBusiness('racingTeam', businessId) then return nil end
    local record = vehicles.getVehicleById(businessId, vehicleId)
    if not record then return nil end
    local key = vehicles.getBusinessVehicleIdentifier(businessId, vehicleId)
    local owner = owners[key]
    if not owner or owner.record ~= record then
      local runtime = core_vehicle_manager.getVehicleData(vehId)
      local data = deepcopy(record)
      data.id = key
      data.model = record.model or record.model_key or (record.vehicleConfig and record.vehicleConfig.model_key)
      data.config = deepcopy(type(record.config) == 'table' and record.config or (runtime and runtime.config))
      if not data.model or type(data.config) ~= 'table' then return nil end
      data.config.vars = deepcopy(record.vars or data.config.vars or {})
      data.partConditions = deepcopy(record.partConditions or {})
      data.niceName = record.niceName or record.name or data.model
      owners[key] = {businessId = businessId, vehicleId = vehicleId, record = record, data = data, key = key}
    end
    return key
  end
  local records = setmetatable({}, {__index = function(_, id)
    if businessKey(id) then return current(owners[id]) and owners[id].data or nil end
    return inventory().getVehicles()[id]
  end})
  function api.getVehicles() return records end
  function api.getVehicle(id) return records[id] end
  function api.getInventoryIdFromVehicleId(id) return resolve(id) end
  function api.getCurrentVehicle()
    local veh = be:getPlayerVehicle(0)
    if veh then return resolve(veh:getID()) end
  end
  function api.getVehicleIdFromInventoryId(id)
    if businessKey(id) then
      local owner = owners[id]
      return current(owner) and fleet().getSpawnedVehicleId(owner.businessId, owner.vehicleId) or nil
    end
    return inventory().getVehicleIdFromInventoryId(id)
  end
  function api.getMapInventoryIdToVehId()
    return setmetatable({}, {__index = function(_, id) return api.getVehicleIdFromInventoryId(id) end})
  end
  function api.getVehicleNiceNameTranslated(id)
    if businessKey(id) then return records[id] and records[id].niceName end
    return inventory().getVehicleNiceNameTranslated(id)
  end
  function api.setTransientBuild(id, enabled)
    if businessKey(id) then
      generations[id] = (generations[id] or 0) + 1
      transient[id] = enabled == true or nil
      return
    end
    return inventory().setTransientBuild(id, enabled)
  end
  function api.isTransientBuild(id)
    if businessKey(id) then return transient[id] == true end
    return inventory().isTransientBuild(id)
  end
  function api.isDamageRestorePending(id)
    if businessKey(id) then return false end
    return inventory().isDamageRestorePending and inventory().isDamageRestorePending(id)
  end
  function api.setVehicleDirty(id)
    if not businessKey(id) then return inventory().setVehicleDirty(id) end
    local owner = owners[id]
    if not authorized(owner) then return false end
    local session = inputs.dynoSession
    local active = session.active and session.inventoryId == id
    local config = active and session.originalConfig or owner.data.config
    local conditions = active and session.originalPartConditions or owner.data.partConditions
    return fleet().updateVehicle(owner.businessId, owner.vehicleId, {
      config = deepcopy(config), vars = deepcopy(config and config.vars or {}), partConditions = deepcopy(conditions),
      maintenanceState = deepcopy(owner.data.maintenanceState), maintenanceComputerState = deepcopy(owner.data.maintenanceComputerState),
    })
  end
  function api.updatePartConditions(vehId, id, callback)
    if not businessKey(id) then return inventory().updatePartConditions(vehId, id, callback) end
    local owner = owners[id]
    local mapped = api.getVehicleIdFromInventoryId(id)
    local object = mapped and getObjectByID(mapped)
    if not authorized(owner) or not object or (vehId and vehId ~= mapped) then
      if callback then callback(false) end
      return false
    end
    if transient[id] then if callback then callback() end; return true end
    local generation = generations[id]
    core_vehicleBridge.requestValue(object, function(response)
      if not authorized(owner) or api.getVehicleIdFromInventoryId(id) ~= mapped then
        if callback then callback(false) end
        return
      end
      if transient[id] or generations[id] ~= generation then if callback then callback() end; return end
      if not response or type(response.result) ~= 'table' then if callback then callback(false) end; return end
      owner.data.partConditions = require('overhaul/lib/vehicles/fuelConditions')(owner.data.partConditions, deepcopy(response.result))
      api.setVehicleDirty(id)
      if callback then callback() end
    end, 'getPartConditions')
    return true
  end
  function api.spawnVehicle(id, mode, callback, position, preserve, options)
    if not businessKey(id) then return inventory().spawnVehicle(id, mode, callback, position, preserve, options) end
    local owner = owners[id]
    if not authorized(owner) then if callback then callback(false, 'Team vehicle is unavailable.') end; return nil end
    generations[id] = (generations[id] or 0) + 1
    local object = fleet().replaceVehicleForDyno(owner.businessId, owner.vehicleId,
      owner.data.config, owner.data.partConditions, callback, options and options.prepareReplacement)
    if object and transient[id] and inputs.parts and inputs.parts.vehicle then
      inputs.parts.vehicle.protectDynoSteering(object)
    end
    return object
  end
  function api.completeVehiclePlacement(id, vehId)
    if businessKey(id) then return true end
    if inventory().completeVehiclePlacement then return inventory().completeVehiclePlacement(id, vehId) end
  end
  function api.removeVehicleObject(id, ...)
    if businessKey(id) then
      local owner = owners[id]
      return current(owner) and fleet().removeBusinessVehicleObject(owner.businessId, owner.vehicleId)
    end
    return inventory().removeVehicleObject(id, ...)
  end
  setmetatable(api, {__index = function(_, name) return inventory()[name] end})

  local function ownerFor(context)
    local id = context and context.inventoryId or inputs.dynoSession.inventoryId
    if not id then
      local veh = be:getPlayerVehicle(0)
      id = veh and resolve(veh:getID())
    end
    return id and owners[id]
  end
  local function account(owner)
    return authorized(owner) and overhaul_career_economy_bank.getBusinessAccount('racingTeam', owner.businessId) or nil
  end
  local function canPay(amount, context)
    local owner = ownerFor(context)
    if not owner then return nil end
    local payer = account(owner)
    return payer ~= nil and (tonumber(payer.balance) or 0) >= amount
  end
  local function pay(amount, reason, context)
    local owner = ownerFor(context)
    if not owner then return nil end
    local payer = account(owner)
    if not payer then return false end
    local label = reason and reason.label or 'Dyno service'
    return overhaul_career_economy_bank.payFromAccount({money = {amount = amount, canBeNegative = false}},
      payer.id, label, label, metadata.tag(reason, reason and reason.category or 'service', {businessId = owner.businessId, vehicleId = owner.key})) == true
  end
  local function refund(amount, label, context)
    local owner = ownerFor(context)
    if not owner then return nil end
    local payer = current(owner) and overhaul_career_economy_bank.getBusinessAccount('racingTeam', owner.businessId)
    if not payer then return false end
    return overhaul_career_economy_bank.rewardToAccount({money = {amount = amount}}, payer.id,
      label, label, metadata.tag(nil, 'refund', {businessId = owner.businessId, vehicleId = owner.key})) == true
  end
  local function service(id)
    local owner = owners[id]
    if not inputs.dynoSession.active or inputs.dynoSession.inventoryId ~= id or not authorized(owner) then return nil end
    return owner
  end
  local function syncMaintenance(id)
    local owner = service(id)
    local vehId = owner and api.getVehicleIdFromInventoryId(id)
    local object = vehId and getObjectByID(vehId)
    if not object then return false end
    api.setVehicleDirty(id)
    object:queueLuaCommand("extensions.load('overhaulMaintenance'); " ..
      vehicleCommands.call('overhaulMaintenance', 'initFromSave', owner.data.maintenanceState, nil))
    return true
  end
  return {
    inventory = api, resolve = resolve, owners = owners, isTeam = businessKey, service = service,
    canPay = canPay, pay = pay, refund = refund, syncMaintenance = syncMaintenance,
    reset = function() table.clear(owners); table.clear(transient); table.clear(generations) end,
    retire = function() retired = true; table.clear(owners); table.clear(transient); table.clear(generations) end,
  }
end

return M
