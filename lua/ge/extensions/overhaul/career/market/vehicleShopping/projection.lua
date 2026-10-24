-- Fields exposed by VehicleList, VehicleCard/useShopVehicle, the filter/sort menus and PhoneMarketplace.
-- Full nested records stay with stock and are fetched separately for one detail or purchase.
local M = {}
local CARD_FIELDS = {
  'shopId', 'id', 'uid', 'Name', 'Brand', 'niceName', 'model_key', 'config_name', 'preview',
  'year', 'Value', 'valueAdjusted', 'marketValue', 'marketValueAdjusted', 'Mileage',
  'Power', 'Torque', 'Weight', 'Drivetrain', 'Transmission', 'Fuel Type', 'Body Style',
  'Config Type', 'Country', 'Top Speed', '0-60 mph', '0-100 km/h',
  'sellerId', 'sellerName', 'salesChannel', 'remotePurchaseAllowed', 'garageDeliveryAllowed',
  'deliveryDiscount', 'negotiationPossible', 'discountPercentage',
  'distance', 'quickTravelPrice', 'soldViewCounter', '__sold', '__soldAt',
}

function M.card(vehicle)
  local card = {}
  for _, key in ipairs(CARD_FIELDS) do
    card[key] = vehicle[key]
  end
  if vehicle.pos and vehicle.pos.x then
    card.pos = {x = vehicle.pos.x, y = vehicle.pos.y, z = vehicle.pos.z}
  end
  for _, key in ipairs({'insuranceClass', 'requiredInsurance'}) do
    if type(vehicle[key]) == 'table' then card[key] = {name = vehicle[key].name} end
  end
  return card
end

return M
