-- Held wages belong to the registering owner, including accrual, release and completion
-- guards. This registry neither holds money nor adds a second payment/ledger mutation.
-- Its registrations survive a payment-only reload so existing shift handles remain usable.
local M = {}
local registrations = require("overhaul/lib/ledger/registrations").new()

-- register(owner, {hold = fn}) returns an opaque handle and a disposer bound to the owner.
function M.register(owner, definition)
  assert(type(definition) == "table" and type(definition.hold) == "function", "wage holder needs hold")
  return registrations.register(owner, {hold = definition.hold})
end

function M.hold(handle, price, reason, fullReward)
  local holder = registrations.get(handle)
  if not holder then return false, "wage holder unavailable" end
  local accepted, problem = holder.hold(price, reason, fullReward)
  if accepted == true then return true end
  return false, problem or "wage holder refused"
end

return M
