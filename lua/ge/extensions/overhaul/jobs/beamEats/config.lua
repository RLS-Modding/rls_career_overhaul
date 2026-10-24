-- BeamEats missing-field policy shared by the owner and pay helpers.
-- Public config remains mutable, so resolve at use while keeping the legacy absent-field values.
local M = {}

local defaults = {
  roughEventRatingPenalty = 0.35,
  lateDeliveryRatingPenalty = 0.6,
  onTimeRatingBonus = 0.25,
  ratingPullTowardFive = 0.2,
  ratingDampeningCount = 4,
  maxRatingBonus = 0.9,
  recentRestaurantCooldown = 2,
  dropoffExpandStep = 500,
  dropoffRoadCheckAttempts = 15,
  dropoffRoadDistanceFactor = 2.0,
  localRestaurantPoolSize = 3,
  minDeliveryAirDistance = 600,
  localDropoffMaxCap = 3500,
  longHaulDropoffMaxCap = 8000,
  longHaulDropoffStartMin = 2000,
  longHaulChanceMin = 0.18,
  longHaulChancePerRating = 0.03,
  restaurantPickAttempts = 6,
}

function M.value(config, name)
  return config[name] or defaults[name]
end

function M.number(config, name)
  return tonumber(config[name]) or defaults[name]
end

return M
