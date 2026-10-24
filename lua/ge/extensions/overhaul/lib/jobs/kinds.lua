-- Job kind catalog discovery and action outcomes.
-- Definitions come from manifests; persisted kind ids remain unchanged.
local manifests = require('overhaul/lib/platform/manifests')
local activities = require('overhaul/lib/activity/catalog')
local economy = require('overhaul/lib/career/activitySections')
local optional = require('overhaul/lib/platform/optional')
local M = {dir = '/gameplay/overhaul/jobs/kinds/'}
local absentPolicy = {__index = function() return false end}
M.emptyPolicy = setmetatable({}, absentPolicy)

local function validate(data)
  for _, field in ipairs({'activity', 'economyKey'}) do
    if not manifests.isNonEmptyString(data[field]) then return nil, field .. ' is required' end
  end
  if data.extension ~= nil or data.label ~= nil then return nil, 'owner and label belong to the activity' end
  for _, field in ipairs({'equipment', 'vehicleRoles', 'cargoKinds'}) do
    if data[field] ~= nil and not manifests.isStringList(data[field], true) then return nil, field .. ' must be a string list' end
  end
  if data.payModel ~= nil and type(data.payModel) ~= 'table' then return nil, 'payModel must be an object' end
  if data.roleplayPoi ~= nil then
    if type(data.roleplayPoi) ~= 'table' then return nil, 'roleplayPoi must be an object' end
    for _, field in ipairs({'type', 'icon', 'cardIcon'}) do
      if not manifests.isNonEmptyString(data.roleplayPoi[field]) then return nil, 'roleplayPoi needs ' .. field end
    end
  end
  for _, field in ipairs({'skillLabel', 'workLabel', 'endShiftMessage'}) do
    if data[field] ~= nil and not manifests.isNonEmptyString(data[field]) then return nil, field .. ' must be a nonempty string' end
  end
  if data.policy ~= nil then
    if type(data.policy) ~= 'table' then return nil, 'policy must be an object' end
    for key, value in pairs(data.policy) do
      if type(key) ~= 'string' or type(value) ~= 'boolean' then return nil, 'policy must map names to booleans' end
    end
  end
  if data.handlers ~= nil then
    if type(data.handlers) ~= 'table' then return nil, 'handlers must be an object' end
    for name, handler in pairs(data.handlers) do
      if type(name) ~= 'string' or not name:match('^[%a_][%w_]*$') or type(handler) ~= 'table' or type(handler.module) ~= 'string'
          or not handler.module:match('^overhaul/[%w_/%-]+$') or type(handler.fn) ~= 'string'
          or not handler.fn:match('^[%a_][%w_]*$') then return nil, 'invalid behavior handler reference' end
    end
  end
  return data
end
M.validate = validate
-- Only available kinds can claim service yards; rejected declarations must leave cargo access intact.
function M.roleplayPois()
  local byKind = {}
  for _, entry in ipairs(M.load().list) do
    if entry.roleplayPoi then byKind[entry.id] = entry.roleplayPoi end
  end
  return byKind
end
function M.load(opts)
  opts = opts or {}
  local entries, rejected = manifests.scan({dir = opts.dir or M.dir, tag = 'jobKinds', validate = validate})
  local owners = opts.activities or activities.load()
  local keys = opts.economyKeys
  if not keys then
    keys = {}
    for _, section in ipairs(economy.sections()) do
      -- Same source as the economy adjuster: the owner's published keys when it lists any.
      local owner = section.extension and optional(section.extension) or nil
      for _, key in ipairs(economy.keys(section, owner)) do keys[key] = true end
    end
  end
  local catalog = {list = {}, byId = {}, rejected = rejected}
  for _, entry in ipairs(entries) do
    local reason
    if not owners.byId[entry.activity] then reason = 'unknown activity ' .. entry.activity
    elseif not keys[entry.economyKey] then reason = 'unknown economy key ' .. entry.economyKey end
    if not reason then
      for name, reference in pairs(entry.handlers or {}) do
        local ok, owner = pcall(require, reference.module)
        if not ok or type(owner) ~= 'table' or type(owner[reference.fn]) ~= 'function' then
          reason = 'unavailable handler ' .. name .. ': ' .. reference.module .. '.' .. reference.fn
          break
        end
      end
    end
    if reason then
      rejected[#rejected + 1] = {file = (opts.dir or M.dir) .. entry.id .. '.json', reason = reason}
      log('W', 'jobKinds', entry.id .. ': ' .. reason)
    else
      entry.activityOwner = owners.byId[entry.activity].extension
      entry.policy = setmetatable(entry.policy or {}, absentPolicy)
      catalog.list[#catalog.list + 1], catalog.byId[entry.id] = entry, entry
    end
  end
  return catalog
end
function M.outcome(catalog, savedId)
  local kind = catalog.byId[savedId]
  if kind then return {status = 'available', kind = kind} end
  return {status = 'missingKind', kindId = savedId, recoverable = true}
end
function M.handler(kind, name, ...)
  local reference = kind and kind.handlers and kind.handlers[name]
  if not reference then return nil, 'kind has no ' .. tostring(name) .. ' handler' end
  local owner = require(reference.module)
  local fn = owner[reference.fn]
  if type(fn) ~= 'function' then return nil, 'kind handler unavailable' end
  return fn(...)
end
return M
