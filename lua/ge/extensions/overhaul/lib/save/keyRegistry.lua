-- Persistence metadata for named file families and their current owners.
-- Registration describes existing writes and serializers; it never dispatches capture or changes save paths.
local M = {}

M.PHASES = {profile = true, vehicleSave = true, deferred = true, immediate = true, import = true}
M.ROOTS = {slot = true, profile = true, user = true}
M.addonKeysDir = "/gameplay/overhaul/save/keys/"

local keys = {}
local instances = {}
local addonKeys = {}

local function fail(message)
  log("E", "saveKeyRegistry", message)
  return nil, message
end

local function copyDescriptor(descriptor)
  local files = {}
  for i, file in ipairs(descriptor.files) do files[i] = file end
  return {key = descriptor.key, owner = descriptor.owner, files = files, phase = descriptor.phase,
    required = descriptor.required, async = descriptor.async, root = descriptor.root or "slot",
    writer = descriptor.writer and {pretty = descriptor.writer.pretty, numberPrecision = descriptor.writer.numberPrecision},
    capture = descriptor.capture, restore = descriptor.restore}
end

local function validateFiles(descriptor)
  for _, file in ipairs(descriptor.files) do
    if type(file) ~= "string" or file == "" or file:sub(1, 1) == "/" or file:find("\\", 1, true)
      or file:find(":", 1, true) or ("/" .. file .. "/"):find("/../", 1, true) then
      return descriptor.key .. ": invalid file " .. tostring(file)
    end
  end
end

local function validateWriter(descriptor)
  local writer = descriptor.writer
  if type(writer) ~= "table" then return descriptor.key .. ": invalid writer" end
  if writer.pretty ~= nil and type(writer.pretty) ~= "boolean" then return descriptor.key .. ": invalid pretty" end
  local precision = writer.numberPrecision
  if precision ~= nil and (type(precision) ~= "number" or precision < 0 or precision % 1 ~= 0) then
    return descriptor.key .. ": invalid numberPrecision"
  end
end

-- The first problem with a descriptor, or nil when it is valid.
local function validate(descriptor)
  if type(descriptor) ~= "table" then return "descriptor must be a table" end
  if type(descriptor.key) ~= "string" or not descriptor.key:match("^[%w_]+%.[%w_.]+$") then
    return "invalid key " .. tostring(descriptor.key)
  end
  if type(descriptor.owner) ~= "string" or descriptor.owner == "" then return descriptor.key .. ": owner required" end
  if not M.PHASES[descriptor.phase] then return descriptor.key .. ": unknown phase " .. tostring(descriptor.phase) end
  if type(descriptor.required) ~= "boolean" then return descriptor.key .. ": required must be true or false" end
  if type(descriptor.files) ~= "table" or #descriptor.files == 0 then return descriptor.key .. ": files required" end
  local fileProblem = validateFiles(descriptor)
  if fileProblem then return fileProblem end
  if descriptor.async ~= nil and (type(descriptor.async) ~= "string" or descriptor.async == "") then
    return descriptor.key .. ": invalid async name"
  end
  if descriptor.root ~= nil and not M.ROOTS[descriptor.root] then
    return descriptor.key .. ": unknown root " .. tostring(descriptor.root)
  end
  for _, field in ipairs({"capture", "restore"}) do
    if descriptor[field] ~= nil and type(descriptor[field]) ~= "function" then return descriptor.key .. ": invalid " .. field end
  end
  if descriptor.writer ~= nil then return validateWriter(descriptor) end
end

-- Registration replacement retains order while disposal remains bound to the matching owner instance.
function M.register(descriptor, instance)
  local problem = validate(descriptor)
  if problem then return fail(problem) end
  local existing = keys[descriptor.key]
  if existing and existing.owner ~= descriptor.owner then
    return fail(descriptor.key .. ": already registered by " .. existing.owner)
  end
  keys[descriptor.key] = copyDescriptor(descriptor)
  -- Metadata refreshes do not replace an owner's live adapter or its callbacks.
  if instance ~= nil then
    instances[descriptor.key] = instance
  elseif existing and instances[descriptor.key] ~= nil then
    keys[descriptor.key].capture = descriptor.capture or existing.capture
    keys[descriptor.key].restore = descriptor.restore or existing.restore
  end
  return copyDescriptor(keys[descriptor.key])
end

-- Registers several descriptors; returns the count stored.
function M.registerAll(list)
  local count = 0
  for _, descriptor in ipairs(list) do
    if M.register(descriptor) then count = count + 1 end
  end
  return count
end

-- Only the registering instance may withdraw its key; old unload handlers cannot remove a reload.
function M.unregister(key, instance)
  if not keys[key] or instance == nil or instances[key] ~= instance then return false end
  keys[key], instances[key] = nil, nil
  return true
end

function M.isCurrent(key, instance)
  return keys[key] ~= nil and instance ~= nil and instances[key] == instance
end

-- Reads a manifest entry as a descriptor; the manifest id becomes the key.
local function addonDescriptor(data)
  local descriptor = {}
  for field, value in pairs(data) do descriptor[field] = value end
  descriptor.key = data.id
  if descriptor.required == nil then descriptor.required = false end
  return descriptor
end

-- Discover add-on metadata through the VFS without adding a core owner roster.
function M.discoverAddonKeys()
  local manifests = require('overhaul/lib/platform/manifests')
  local entries, rejected = manifests.scan({dir = M.addonKeysDir, tag = "saveKeyRegistry", validate = function(data)
    local descriptor = addonDescriptor(data)
    local problem = validate(descriptor)
    if problem then return nil, problem end
    if keys[descriptor.key] and addonKeys[descriptor.key] ~= descriptor.owner then
      return nil, descriptor.key .. ": already registered outside add-on manifests"
    end
    descriptor.id, descriptor.order = data.id, data.order
    return descriptor
  end})
  local accepted, count = {}, 0
  for _, descriptor in ipairs(entries) do
    if M.register(descriptor) then
      accepted[descriptor.key] = descriptor.owner
      count = count + 1
    end
  end
  addonKeys = accepted
  return count, rejected
end

function M.isAddon(key, owner)
  return addonKeys[key] ~= nil and (owner == nil or addonKeys[key] == owner)
end

function M.get(key)
  local descriptor = keys[key]
  return descriptor and copyDescriptor(descriptor) or nil
end

-- All descriptors (optionally one owner's), sorted by key.
function M.list(owner)
  local result = {}
  for _, descriptor in pairs(keys) do
    if owner == nil or descriptor.owner == owner then result[#result + 1] = copyDescriptor(descriptor) end
  end
  table.sort(result, function(a, b) return a.key < b.key end)
  return result
end

-- A file pattern as a Lua pattern: "*" matches within one path segment.
local function patternOf(file)
  return "^" .. file:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*", "[^/]*") .. "$"
end

-- The descriptor covering a path relative to `root` (default "slot"), or nil.
function M.matchFile(relativePath, root)
  if type(relativePath) ~= "string" then return nil end
  local path = relativePath:gsub("\\", "/"):gsub("^/+", "")
  root = root or "slot"
  for _, descriptor in ipairs(M.list()) do
    if descriptor.root == root then
      for _, file in ipairs(descriptor.files) do
        if path:match(patternOf(file)) then return descriptor end
      end
    end
  end
  return nil
end

return M
