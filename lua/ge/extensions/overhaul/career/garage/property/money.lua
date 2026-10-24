-- Money changes and notifications shared by property mortgage and rental owners.
-- Dependencies are resolved per call so retained helpers use the current career providers.
local M = {}
local phoneLayout = require("overhaul/lib/phone/layoutOwner")

local KIND = { success = "success", error = "error", warning = "warning", info = "invite" }
local SOUND = { soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open" }

-- deps() is read on every call and returns: payment, playerAttributes, facilities, phoneLayout.
local function getGarageLabel(deps, garageId)
  local _, _, facilities = deps()
  local facility = facilities and facilities.getFacility("garage", garageId)
  return (facility and facility.name) or ("Garage " .. tostring(garageId))
end

local function canAfford(deps, amount)
  if amount <= 0 then return true end
  local payment, attributes = deps()
  if payment and payment.canPay then
    return payment.canPay({money = {amount = amount, canBeNegative = false}})
  end
  local money = (attributes and attributes.getAttributeValue and attributes.getAttributeValue("money")) or 0
  return money >= amount
end

local function applyMoneyDelta(deps, opts, amount, garageId, context)
  local payment, attributes, facilities = deps()
  local facility = garageId and facilities and facilities.getFacilityIfExists
    and facilities.getFacilityIfExists("garage", garageId)
  local finance = require("overhaul/lib/finance/metadata").copy(context and context.finance or {vehicleRelated = false})
  finance.locationId, finance.locationName = garageId, facility and facility.name
  local category = context and context.category or opts.category
  if amount < 0 then
    if payment and payment.pay then
      return payment.pay({money = {amount = math.abs(amount), canBeNegative = false}}, require("overhaul/lib/finance/metadata").tag({label = opts.label, description = opts.payDescription}, category, finance))
    end
  elseif amount > 0 then
    if payment and payment.reward then
      return payment.reward({money = {amount = amount, canBeNegative = false}}, require("overhaul/lib/finance/metadata").tag({label = opts.label, description = opts.rewardDescription}, category, finance), true)
    end
  end
  if attributes and attributes.addAttributes then
    attributes.addAttributes({money = amount}, require("overhaul/lib/finance/metadata").tag({label = opts.label}, category, finance), true)
    return true
  end
  return false
end

function M.new(opts)
  local deps = opts.deps
  local notificationProvider = opts.notificationProvider or phoneLayout.get
  local helpers = {}

  function helpers.getGarageLabel(garageId)
    return getGarageLabel(deps, garageId)
  end

  function helpers.notify(type, title, msg, channelKey, entityId)
    local _, _, _, layout = deps()
    if not layout then layout = notificationProvider() end
    if layout and layout.fireNotification and channelKey then
      local payload = {
        title = title,
        message = msg,
        kind = KIND[type] or "invite",
        ttl = 8,
        source = opts.source,
        sound = { soundClass = SOUND.soundClass, type = SOUND.type },
      }
      local notifyOpts = nil
      if entityId ~= nil then
        local id = tostring(entityId)
        payload.entityId = id
        notifyOpts = { entityId = id }
      end
      layout.fireNotification(channelKey, payload, notifyOpts)
    end
  end

  function helpers.canAfford(amount)
    return canAfford(deps, amount)
  end

  function helpers.applyMoneyDelta(amount, garageId, context)
    return applyMoneyDelta(deps, opts, amount, garageId, context)
  end

  return helpers
end

return M
