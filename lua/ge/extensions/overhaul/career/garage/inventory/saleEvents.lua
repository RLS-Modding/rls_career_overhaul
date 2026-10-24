-- Inventory sale observers, run synchronously in subscription order after a sale completes.
-- Kept in its own required module so the subscriber list survives a reload of inventory.lua alone.
local M = {}

local subscribers = {}
local nextOrder = 0

function M.subscribe(ownerId, callback)
  assert(type(ownerId) == "string" and type(callback) == "function")
  nextOrder = nextOrder + 1
  local subscription = {order = nextOrder, callback = callback}
  subscribers[ownerId] = subscription
  return function()
    if subscribers[ownerId] == subscription then subscribers[ownerId] = nil end
  end
end

function M.publish(inventoryId, salePrice, marketValue, soldVehicle)
  local ordered = {}
  for _, subscriber in pairs(subscribers) do ordered[#ordered + 1] = subscriber end
  table.sort(ordered, function(a, b) return a.order < b.order end)
  for _, subscriber in ipairs(ordered) do
    subscriber.callback(inventoryId, salePrice, marketValue, soldVehicle)
  end
end

return M
