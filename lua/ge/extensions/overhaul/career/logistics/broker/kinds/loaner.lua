-- Equipment admission and bay areas stay with the rental kind, separate from its billing lifecycle.
local presence = require("overhaul/career/logistics/broker/presence")
local M = {}
function M.requirements(ctx, row)
  local requirements = {}
  for _, flag in ipairs(row.unlockFlags or {}) do
    requirements[#requirements + 1] = ctx.flagRequirement(flag)
  end
  return requirements
end
function M.pickupArea(ctx, row)
  local fac = row.origin and ctx.gen().getFacilityById(row.origin.facId)
  return presence.area(row, fac,
    {"loanerNonTrailerSpots", "loanerTrailerSpots", "inspectSpots", "pickUpSpots"})
end
function M.fit(profile, row, capabilities)
  local equipment = capabilities.getProfile(row)
  if not equipment then return nil end
  if equipment.isTrailer then
    return capabilities.canTowTrailer(profile, {couplerClass = capabilities.getOfferCouplerClass(row)})
  end
  return true
end
return M
