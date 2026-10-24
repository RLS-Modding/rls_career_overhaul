-- Ordered payer and service registrations for sponsored purchases.
-- Owner lifetimes expire stale registrations while replacement disposal remains isolated.
local registrations = require("overhaul/lib/ledger/registrations")

local M = {}

local payers, services = registrations.new(), registrations.new()

-- The name of the first active payer; nil means no cover.
local function sponsorName()
  for _, entry in ipairs(payers.entries()) do
    if entry.value.isActive() then return entry.value.name() end
  end
end

-- Disposers are bound to their registration so stale cleanup cannot remove a replacement payer.
function M.registerPayer(owner, definition)
  assert(type(definition) == "table" and type(definition.isActive) == "function" and
    type(definition.name) == "function", "sponsor payer needs isActive and name")
  local _, dispose = payers.register(owner, {isActive = definition.isActive, name = definition.name}, definition.order)
  return dispose
end

-- Resolve current owner callbacks and keep service cleanup bound to its registration.
function M.registerService(owner, definition)
  assert(type(definition) == "table" and type(definition.matches) == "function", "sponsored service needs matches")
  assert(definition.onCovered == nil or type(definition.onCovered) == "function", "onCovered must be a function")
  local _, dispose = services.register(owner, {matches = definition.matches, onCovered = definition.onCovered}, definition.order)
  return dispose
end

function M.isSponsored()
  for _, entry in ipairs(payers.entries()) do
    if entry.value.isActive() then return true end
  end
  return false
end

function M.tryCover(price, reason, accountId)
  for _, entry in ipairs(services.entries()) do
    local service = entry.value
    if service.matches(price, reason, accountId) then
      local name = sponsorName()
      if not name then return false end
      if service.onCovered then service.onCovered(name, price, reason, accountId) end
      return true
    end
  end
  return false
end

return M
