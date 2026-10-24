-- Settings schema: discovers setting definitions under gameplay/overhaul/settings/ and validates them.
-- Values stay in the shell extension's single settings file; this module only describes them.
local M = {}

local catalog = require("overhaul/lib/platform/jsonCatalog")

M.dir = "/gameplay/overhaul/settings/"

local TYPES = { boolean = true, number = true, string = true, table = true }

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, nested in pairs(value) do out[key] = copy(nested) end
  return out
end

-- JSON decodes defaults, options and saved values into separate table instances, so compare by content.
local function sameValue(value, option)
  if type(value) ~= "table" or type(option) ~= "table" then return value == option end
  for key, nested in pairs(value) do
    if not sameValue(nested, option[key]) then return false end
  end
  for key in pairs(option) do
    if value[key] == nil then return false end
  end
  return true
end

local function matchesOptions(entry, value)
  for _, option in ipairs(entry.options) do
    if sameValue(value, option) then return true end
  end
  return false
end

local function constraints(entry, value)
  if entry.options and not matchesOptions(entry, value) then return false end
  if entry.range then
    if not catalog.finite(value) then return false end
    if entry.range.min ~= nil and value < entry.range.min then return false end
    if entry.range.max ~= nil and value > entry.range.max then return false end
  end
  return true
end

-- Each check returns nil when the entry passes, or the reason it is rejected.
local function identityProblem(entry)
  if not catalog.validId(entry.key) then return "invalid setting key" end
  if not TYPES[entry.type] or type(entry.default) ~= entry.type then return "default must match setting type" end
  if entry.type == "number" and not catalog.finite(entry.default) then return "default must be finite" end
  if entry.section ~= nil and (type(entry.section) ~= "string" or entry.section == "") then return "invalid section" end
  return nil
end

local function callbackProblem(entry)
  if entry.onChange == nil then return nil end
  local onChange = entry.onChange
  if type(onChange) ~= "table" or type(onChange.extension) ~= "string"
      or not onChange.extension:match("^[%w_]+$") or type(onChange.call) ~= "string"
      or not onChange.call:match("^[%a_][%w_]*$") then
    return "invalid onChange callback"
  end
  return nil
end

local function flagProblem(entry)
  for _, field in ipairs({ "validateSingle", "validateLoaded" }) do
    if entry[field] ~= nil and type(entry[field]) ~= "boolean" then return field .. " must be boolean" end
  end
  return nil
end

local function optionsProblem(entry)
  if entry.options == nil then return nil end
  if type(entry.options) ~= "table" or #entry.options == 0 then return "options must be a nonempty list" end
  for _, option in ipairs(entry.options) do
    if type(option) ~= entry.type or (entry.type == "number" and not catalog.finite(option)) then
      return "option type mismatch"
    end
  end
  return nil
end

local function rangeProblem(entry)
  if entry.range == nil then return nil end
  if entry.type ~= "number" or type(entry.range) ~= "table" then return "range needs a numeric setting" end
  for _, bound in ipairs({ "min", "max" }) do
    if entry.range[bound] ~= nil and not catalog.finite(entry.range[bound]) then return "invalid range bound" end
  end
  if entry.range.min and entry.range.max and entry.range.min > entry.range.max then return "inverted range" end
  return nil
end

local function validate(entry)
  local problem = identityProblem(entry) or callbackProblem(entry) or flagProblem(entry)
    or optionsProblem(entry) or rangeProblem(entry)
  if problem then return nil, problem end
  if not constraints(entry, entry.default) then return nil, "default outside constraints" end
  return entry
end

-- The first definition of a key wins; later duplicates are rejected and logged.
function M.scan()
  local entries, rejected = catalog.scan(M.dir, validate, "overhaul_settingsCatalog")
  local valid, ownerByKey = {}, {}
  for _, entry in ipairs(entries) do
    if ownerByKey[entry.key] then
      local reason = "setting key " .. entry.key .. " already belongs to " .. ownerByKey[entry.key]
      rejected[#rejected + 1] = { id = entry.id, reason = reason }
      log("W", "overhaul_settingsCatalog", reason)
    else
      ownerByKey[entry.key] = entry.id
      valid[#valid + 1] = entry
    end
  end
  return valid, rejected
end

-- Schema and nested defaults are fresh for every owning extension instance.
function M.create()
  local entries = M.scan()
  local defaults, entryByKey = {}, {}
  for _, entry in ipairs(entries) do
    defaults[entry.key] = copy(entry.default)
    entryByKey[entry.key] = entry
  end
  return {
    defaults = defaults,
    acceptsConstraints = function(key, value)
      local entry = entryByKey[key]
      return not entry or constraints(entry, value)
    end,
    acceptsSingle = function(key, value)
      local entry = entryByKey[key]
      return not entry or entry.validateSingle == false
        or (type(value) == entry.type and constraints(entry, value))
    end,
    acceptsLoaded = function(key, value)
      local entry = entryByKey[key]
      return not entry or entry.validateLoaded == false
        or (type(value) == entry.type and constraints(entry, value))
    end,
    list = function() return copy(entries) end,
    onChange = function(key)
      local entry = entryByKey[key]
      return entry and entry.onChange
    end,
  }
end

-- Settings screen: the valid entries plus the rejected ones, or the scan error.
function M.listForUi()
  local scanned, entries, rejected = pcall(M.scan)
  if not scanned then return { settings = {}, rejected = {}, error = tostring(entries) } end
  return { settings = entries, rejected = rejected }
end

return M
