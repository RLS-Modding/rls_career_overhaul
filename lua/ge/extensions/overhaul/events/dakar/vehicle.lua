-- Vehicle helpers for the shared Dakar controller in ../dakar.lua.
-- Owns classification, categorized payments and repair cargo; course.lua owns routes.
-- Construct with new(config); the controller calls the returned service functions.
local M = {}

function M.new(config)
  local function keys(tbl)
    local ret = {}
    for key, _ in pairs(tbl or {}) do table.insert(ret, key) end
    return ret
  end

  local function currentInventoryId()
    local veh = getPlayerVehicle(0)
    return veh and overhaul_career_garage_inventory.getInventoryIdFromVehicleId(veh:getID()) or nil
  end

  local function currentVehicleInfo()
    local invId = currentInventoryId()
    local vehInfo = invId and overhaul_career_garage_inventory.getVehicle(invId) or nil
    local veh = getPlayerVehicle(0)
    return invId, vehInfo, veh
  end

  local function getVehicleValue(invId)
    if overhaul_career_market_valueCalculator and overhaul_career_market_valueCalculator.getInventoryVehicleValue then
      return overhaul_career_market_valueCalculator.getInventoryVehicleValue(invId) or 0
    end
    local veh = invId and overhaul_career_garage_inventory.getVehicle(invId)
    return (veh and (veh.Value or veh.value or veh.configBaseValue)) or 1000
  end

  local function readInfo(model)
    return model and jsonReadFile("/vehicles/" .. model .. "/info.json") or nil
  end

  local function configKeyFromPath(value)
    if type(value) ~= "string" then return nil end
    local key = value:match("([^/\\]+)%.pc$") or value:match("([^/\\]+)$")
    return key ~= "" and key or nil
  end

  local function getConfigKey(vehInfo, veh)
    local vehicleConfig = vehInfo and vehInfo.config
    local candidates = {
      vehicleConfig and vehicleConfig.partConfigFilename or false,
      vehicleConfig and vehicleConfig.partConfig or false,
      vehicleConfig and vehicleConfig.path or false,
      vehInfo and vehInfo.configKey or false,
      vehInfo and vehInfo.key or false,
      veh and veh.partConfig or false
    }

    for _, candidate in ipairs(candidates) do
      local key = configKeyFromPath(candidate)
      if key then return key end
    end
    return nil
  end

  local function readConfigInfo(model, configKey)
    return model and configKey and jsonReadFile("/vehicles/" .. model .. "/info_" .. configKey .. ".json") or nil
  end

  local function bodyStyleLookup(info)
    local lookup = {}
    local raw = info and (info["Body Style"] or info["bodyStyle"] or info["BodyStyle"])
    if type(raw) == "string" then lookup[raw] = true end
    if type(raw) == "table" then
      for _, v in pairs(raw) do lookup[v] = true end
    end
    return lookup
  end

  local function detectClass()
    local invId, vehInfo, veh = currentVehicleInfo()
    local model = vehInfo and (vehInfo.model or vehInfo.modelKey)
    local configKey = getConfigKey(vehInfo, veh)
    local info = readConfigInfo(model, configKey) or readInfo(model)
    local bodyStyles = bodyStyleLookup(info)

    for _, classId in ipairs(config.classOrder or {"Heavy", "SSV", "Raid", "Unlimited"}) do
      local rule = config.classes[classId]
      for _, m in ipairs(rule.models or {}) do
        if model == m then
          return {
            id = classId,
            label = rule.label or classId,
            rule = rule,
            model = model,
            configKey = configKey,
            bodyStyles = keys(bodyStyles),
            inventoryId = invId,
            vehicleName = vehInfo and (vehInfo.niceName or vehInfo.model) or "Current Vehicle",
            vehicleValue = getVehicleValue(invId)
          }
        end
      end
    end

    for _, classId in ipairs(config.classOrder or {"Heavy", "SSV", "Raid", "Unlimited"}) do
      local rule = config.classes[classId]
      local matches = classId == "Unlimited"
      for _, style in ipairs(rule.bodyStyles or {}) do
        matches = matches or bodyStyles[style]
      end
      if matches then
        return {
          id = classId,
          label = rule.label or classId,
          rule = rule,
          model = model,
          configKey = configKey,
          bodyStyles = keys(bodyStyles),
          inventoryId = invId,
          vehicleName = vehInfo and (vehInfo.niceName or vehInfo.model) or "Current Vehicle",
          vehicleValue = getVehicleValue(invId)
        }
      end
    end
  end

  local function getPlayerCargoContainers(callback)
    if not overhaul_career_logistics_general or not overhaul_career_logistics_general.getNearbyVehicleCargoContainers then
      callback({})
      return
    end
    overhaul_career_logistics_general.getNearbyVehicleCargoContainers(callback)
  end

  local function getRepairContainers(containers, vehId)
    local valid = {}
    local totalSlots = 0
    for _, con in ipairs(containers or {}) do
      if con.vehId == vehId and con.cargoTypesLookup and con.cargoTypesLookup.parcel and (con.freeCargoSlots or 0) > 0 then
        table.insert(valid, con)
        totalSlots = totalSlots + math.floor((con.freeCargoSlots or 0) / config.repairKit.slots) * config.repairKit.slots
      end
    end
    table.sort(valid, function(a, b) return (a.freeCargoSlots or 0) > (b.freeCargoSlots or 0) end)
    return valid, totalSlots
  end

  local function payMoney(amount, label)
    local cost = { money = { amount = amount, canBeNegative = false } }
    if overhaul_career_economy_payment.canPay and not overhaul_career_economy_payment.canPay(cost) then return false end
    return overhaul_career_economy_payment.pay(cost, { label = label or "Dakar event sign-up", category = "activity:dakar" })
  end

  local function canPayMoney(amount)
    if amount <= 0 then return true end
    local cost = { money = { amount = amount, canBeNegative = false } }
    return not overhaul_career_economy_payment.canPay or overhaul_career_economy_payment.canPay(cost)
  end

  local function addMoney(amount, label)
    overhaul_career_economy_payment.reward({ money = { amount = amount } }, { label = label or "Dakar reward", category = "activity:dakar", tags = { "gameplay", "dakar" } })
  end

  local function scaleRewardMoney(amount)
    amount = math.max(0, math.floor((tonumber(amount) or 0) + 0.5))
    if overhaul_career_economy_difficultyMode and overhaul_career_economy_difficultyMode.scaleFlatRewards then
      local reward = { money = amount }
      overhaul_career_economy_difficultyMode.scaleFlatRewards(reward, { includeMoney = true })
      return math.max(0, math.floor((tonumber(reward.money) or amount) + 0.5))
    end
    return amount
  end

  local function addRepairCargo(containers, count)
    local ids = {}
    if not overhaul_career_logistics_parcelManager or not overhaul_career_logistics_parcelManager.addCargo then return ids end
    local remaining = count
    for _, container in ipairs(containers or {}) do
      local kitsHere = math.min(remaining, math.floor((container.freeCargoSlots or 0) / config.repairKit.slots))
      for _ = 1, kitsHere do
        local cargoId = overhaul_career_logistics_generator.allocateCargoId()
        local kitKey = config.levelId .. ":" .. tostring(os.time()) .. ":" .. tostring(cargoId)
        local cargo = {
          id = cargoId,
          groupId = overhaul_career_logistics_generator.allocateCargoGroupId(),
          name = "Dakar Repair Kit",
          type = "parcel",
          slots = config.repairKit.slots,
          weight = config.repairKit.weightKg,
          location = deepcopy(container.location),
          origin = { type = "dakarRegistration" },
          destination = { type = "dakarEvent" },
          offerExpiresAt = math.huge,
          generatedAtTimestamp = os.time(),
          data = { dakarRepairKit = true, dakarKitKey = kitKey },
          automaticDropOff = false,
          hiddenInFacility = true,
          modifiers = {},
          rewards = { money = 0 }
        }
        overhaul_career_logistics_parcelManager.addCargo(cargo)
        table.insert(ids, kitKey)
      end
      remaining = remaining - kitsHere
      if remaining <= 0 then break end
    end
    if overhaul_career_logistics_general and overhaul_career_logistics_general.requestUpdateContainerWeights then
      overhaul_career_logistics_general.requestUpdateContainerWeights()
    end
    return ids
  end

  -- Freight reassigns numeric IDs on restore; the saved key lives in parcel data.
  local function getRepairCargo(key)
    local manager = overhaul_career_logistics_parcelManager
    if not manager then return nil end
    if type(key) == "number" then
      local cargo = manager.getCargoById(key)
      return cargo and cargo.data and cargo.data.dakarRepairKit and cargo or nil
    end
    local matches = manager.getAllCargoCustomFilter(function(cargo)
      return cargo.data and cargo.data.dakarKitKey == key and cargo.location.type ~= "delete"
    end)
    return matches[1]
  end

  local function removeRepairCargo(key)
    local cargo = getRepairCargo(key)
    if cargo then
      overhaul_career_logistics_parcelManager.changeCargoLocation(cargo.id, { type = "delete" })
      cargo.data.delivered = true
      -- Removed cargo must not be resurrected by freight's inventory binding.
      cargo.logisticsBinding = nil
    end
    if overhaul_career_logistics_general and overhaul_career_logistics_general.requestUpdateContainerWeights then
      overhaul_career_logistics_general.requestUpdateContainerWeights()
    end
  end



  return {
    currentVehicleInfo = currentVehicleInfo,
    getVehicleValue = getVehicleValue,
    detectClass = detectClass,
    getPlayerCargoContainers = getPlayerCargoContainers,
    getRepairContainers = getRepairContainers,
    payMoney = payMoney,
    canPayMoney = canPayMoney,
    addMoney = addMoney,
    scaleRewardMoney = scaleRewardMoney,
    addRepairCargo = addRepairCargo,
    getRepairCargo = getRepairCargo,
    removeRepairCargo = removeRepairCargo
  }
end

return M
