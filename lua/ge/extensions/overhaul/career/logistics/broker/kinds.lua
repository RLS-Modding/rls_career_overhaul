-- Cargo kinds: each kind's workflow lives in its handler (broker/kinds/<kind>.lua); one registry per broker. Builtins work before discovery; discover() adds cargoKinds manifests, which replace a builtin with the same id.
-- Read nop, unavailable, warn, build, validate in order.

local manifests = require("overhaul/lib/platform/manifests")

local M = {}

M.dir = "/gameplay/overhaul/logistics/cargoKinds/"
local TAG = "logisticsBrokerKinds"
local MODULE_PATTERN = "^[%w_][%w_/%.%-]*$"
local HANDLER_FUNCTIONS = { "sync", "reserve", "release", "abandon", "abandonQuote", "pickup" }

local function nop() end

-- Optional handler behaviour; a handler overrides only what its kind does.
local defaults = {
  requirements = function(_, row)
    return {{unlocked = row.unlocked ~= false,
      definition = {lockedReason = {label = row.lockedReason}}}}
  end,
  fit = function() return nil end,
  containerFits = function() return false end,
  pickupArea = function(ctx, row)
    local fac = row.origin and ctx.gen().getFacilityById(row.origin.facId)
    return require("overhaul/career/logistics/broker/presence").area(row, fac)
  end,
  collect = nop,
  collectBoard = nop,
  reservedPickup = function(ctx, job)
    if job.status == "reserved" and job.map == ctx.mapId() and job.origin then
      return {facId = job.origin.facId, psPath = job.origin.psPath, jobId = job.id,
        title = job.title, slots = 0, kind = job.kind}
    end
  end,
  destinations = function() return {} end,
  cargoDelivered = nop,
  vehicleDelivered = nop,
  vehicleAbandoned = nop,
  restoreOffer = nop,
}

local function unavailable() return false, "This load type is unavailable. Restore its add-on to continue." end

-- An uninstalled kind keeps its saved job; each operation fails explicitly, so the broker never branches on the name.
local unknown = {}
for k, v in pairs(defaults) do
  unknown[k] = v
end

unknown.levelBonus = true
unknown.sync = nop
unknown.reserve, unknown.release, unknown.abandon, unknown.pickup = unavailable, unavailable, unavailable, unavailable
unknown.abandonQuote = function() return 0 end

local BUILTIN_SPECS = {
  { id = "parcel", order = 10, handler = "overhaul/career/logistics/broker/kinds/parcel", levelBonus = true },
  { id = "material", order = 20, handler = "overhaul/career/logistics/broker/kinds/material", levelBonus = false },
  { id = "trailer", order = 30, handler = "overhaul/career/logistics/broker/kinds/trailer", levelBonus = true },
  { id = "cars", order = 40, handler = "overhaul/career/logistics/broker/kinds/cars", levelBonus = false },
}

local function warn(message)
  log("W", TAG, message)
end

-- Builds an entry from a spec, or returns nil and the reason when the handler cannot load or lacks a function.
local function build(spec)
  local ok, handler = pcall(require, spec.handler)
  if not ok or type(handler) ~= "table" then return nil, "handler did not load: " .. tostring(handler) end
  for _, name in ipairs(HANDLER_FUNCTIONS) do
    if type(handler[name]) ~= "function" then return nil, "handler is missing " .. name end
  end
  local entry = {}
  for k, v in pairs(defaults) do
    entry[k] = v
  end
  for k, v in pairs(handler) do
    entry[k] = v
  end
  entry.id, entry.order, entry.levelBonus = spec.id, spec.order, spec.levelBonus ~= false
  return entry
end

local function validate(data)
  if
    not manifests.isNonEmptyString(data.handler)
    or not string.match(data.handler, MODULE_PATTERN)
    or string.sub(data.handler, -4) == ".lua"
  then
    return nil, "handler must be a module path (require name, no .lua)"
  end
  if data.levelBonus ~= nil and type(data.levelBonus) ~= "boolean" then
    return nil, "levelBonus must be true or false"
  end
  return { id = data.id, order = data.order, handler = data.handler, levelBonus = data.levelBonus }
end

-- One registry per broker instance.
function M.new()
  local self = {}
  local registry, ordered = {}, {}

  local function install(entries)
    registry, ordered = {}, {}
    for _, entry in ipairs(entries) do
      registry[entry.id] = entry
      ordered[#ordered + 1] = entry
    end
    table.sort(ordered, manifests.byOrderThenId)
  end

  -- Rebuilds the registry from builtins and manifests. Returns the rejected manifests and their reasons.
  function self.discover()
    local specs, rejected = manifests.scan({ dir = M.dir, tag = TAG, validate = validate })
    local entries = {}
    local claimed = {}
    for _, spec in ipairs(specs) do
      local entry, reason = build(spec)
      if entry then
        entries[#entries + 1] = entry
        claimed[spec.id] = true
      else
        rejected[#rejected + 1] = { file = M.dir .. spec.id .. ".json", reason = reason }
        warn("Ignoring cargo kind " .. spec.id .. ": " .. tostring(reason))
      end
    end
    for _, spec in ipairs(BUILTIN_SPECS) do
      if not claimed[spec.id] then entries[#entries + 1] = assert(build(spec), spec.id) end
    end
    install(entries)
    return rejected
  end

  function self.forKind(kind) return registry[kind] or unknown end

  -- Registered kinds in order, for the board and other per-kind sweeps.
  function self.list() return ordered end

  local builtins = {}
  for _, spec in ipairs(BUILTIN_SPECS) do
    builtins[#builtins + 1] = assert(build(spec), spec.id)
  end
  install(builtins)
  return self
end

return M
