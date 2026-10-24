-- Owner-registered vehicle policies resolved within independent domains.
-- Per-frame providers are called directly; stale registrations expire with their declared owner lifetimes.
local M = {}

-- Do not merge policy domains because membership in one does not imply membership in another.
local DOMAINS = {
  "offenseExempt",          -- traffic offense detection and speed cameras skip the vehicle
  "speedImmune",            -- the player's speed-trap and red-light fines are off (providers may ignore the id)
  "pursuitImmune",          -- police never pick the vehicle as a pursuit target
  "pursuitOutcomeIgnored",  -- the player's pursuit events (fines, arrests, pursuit state) are not processed
  "roleLocked",             -- traffic may not change the vehicle's driver role (a taxi in service keeps it)
}

local isDomain = {}
for _, domain in ipairs(DOMAINS) do isDomain[domain] = true end
M.DOMAINS = DOMAINS

-- Call providers directly so errors propagate and per-frame iteration order remains stable.
local providers = {}      -- domain -> array of fn, the only thing query() touches
local roleProviders = {}
local registrations = {}  -- owner -> domain and role predicates sharing one loaded lifetime
local nextOrder = 0

for _, domain in ipairs(DOMAINS) do providers[domain] = {} end

-- Rebuilds every domain's provider array in registration order.
local function rebuild()
  for _, domain in ipairs(DOMAINS) do
    local list = {}
    for _, registration in pairs(registrations) do
      if registration.fns[domain] then list[#list + 1] = registration end
    end
    table.sort(list, function(a, b) return a.order < b.order end)
    for i, registration in ipairs(list) do list[i] = registration.fns[domain] end
    providers[domain] = list
  end
  roleProviders = {}
  local ordered = {}
  for _, registration in pairs(registrations) do ordered[#ordered + 1] = registration end
  table.sort(ordered, function(a, b) return a.order < b.order end)
  for _, registration in ipairs(ordered) do
    for roleId, predicate in pairs(registration.roles) do
      local list = roleProviders[roleId] or {}
      list[#list + 1] = predicate
      roleProviders[roleId] = list
    end
  end
end

-- Pursuit outcomes fail closed while per-frame domain providers remain direct calls.
local function protectPursuitOutcome(owner, fn)
  local warned = false
  return function(vehId, context)
    local ok, answer = pcall(fn, vehId, context)
    if ok then return answer end
    if not warned then
      warned = true
      log('E', 'vehiclePolicy', owner .. '.pursuitOutcomeIgnored failed: ' .. tostring(answer))
    end
    return false
  end
end

local function validateRoleName(roleId)
  assert(type(roleId) == "string" and roleId:match("^%a[%w_%-]*$"), "vehicle policy: the role must be a descriptive name")
end

-- Optional roles are named facts, independent of police domains; replacement withdraws both together.
function M.register(owner, fns, lifetime, roles)
  assert(type(owner) == "string" and owner ~= "", "vehicle policy: the owner must be a name")
  assert(type(fns) == "table", "vehicle policy: " .. owner .. " registered no providers")
  assert(lifetime == "loaded", "vehicle policy: " .. owner .. " must declare the loaded lifetime")
  for domain, fn in pairs(fns) do
    assert(isDomain[domain], "vehicle policy: " .. owner .. " registered unknown domain " .. tostring(domain))
    assert(type(fn) == "function", "vehicle policy: " .. owner .. "." .. domain .. " must be a function")
  end
  assert(roles == nil or type(roles) == "table", "vehicle policy: " .. owner .. " registered invalid roles")
  for roleId, predicate in pairs(roles or {}) do
    validateRoleName(roleId)
    assert(type(predicate) == "function", "vehicle policy: " .. owner .. "." .. roleId .. " must be a function")
  end
  nextOrder = nextOrder + 1
  local registration = {owner = owner, fns = {}, roles = {}, order = nextOrder}
  for domain, fn in pairs(fns) do
    registration.fns[domain] = domain == 'pursuitOutcomeIgnored' and protectPursuitOutcome(owner, fn) or fn
  end
  for roleId, predicate in pairs(roles or {}) do registration.roles[roleId] = predicate end
  registrations[owner] = registration
  rebuild()
  return function()
    if registrations[owner] ~= registration then return false end
    registrations[owner] = nil
    rebuild()
    return true
  end
end

-- The convenience form replaces the owner's entire registration, just like register().
function M.registerRole(owner, roleId, predicate, lifetime)
  validateRoleName(roleId)
  assert(type(predicate) == "function", "vehicle policy: " .. tostring(owner) .. "." .. roleId .. " must be a function")
  return M.register(owner, {}, lifetime, {[roleId] = predicate})
end

-- Role predicates run directly and in registration order, matching per-frame domain queries.
function M.hasRole(roleId, vehId, context)
  validateRoleName(roleId)
  local list = roleProviders[roleId]
  if not list then return false end
  for i = 1, #list do
    if list[i](vehId, context) then return true end
  end
  return false
end

-- True if any registered owner applies the domain; unknown domains raise.
function M.query(domain, vehId, context)
  local list = providers[domain]
  if not list then error("vehicle policy: unknown domain " .. tostring(domain), 2) end
  for i = 1, #list do
    if list[i](vehId, context) then return true end
  end
  return false
end

-- Registered owner names, in query order (diagnostics and tests).
function M.owners()
  local list = {}
  for _, registration in pairs(registrations) do list[#list + 1] = registration end
  table.sort(list, function(a, b) return a.order < b.order end)
  for i, registration in ipairs(list) do list[i] = registration.owner end
  return list
end

-- Tests only: forget every registration.
function M._reset()
  registrations = {}
  rebuild()
end

return M
