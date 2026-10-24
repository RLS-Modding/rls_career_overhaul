-- Discovers owner-written start defaults and profile-card fields before career modules load.
-- Read registry validation, part loading, initial-save writers and profile readers in order.
local M = {}

local manifests = require('overhaul/lib/platform/manifests')

local START_DEFAULTS_DIR = '/gameplay/overhaul/career/startDefaults/'
local PROFILE_CARDS_DIR = '/gameplay/overhaul/career/profileCards/'
local LOG_TAG = 'career.contributors'

local function validateContributor(data)
  if data.order == math.huge or data.order == -math.huge then return nil, 'order must be finite' end
  if data.pendingField ~= nil and (type(data.pendingField) ~= 'string' or data.pendingField == '') then
    return nil, 'pendingField must name a start choice'
  end
  if data.stage ~= nil and (type(data.stage) ~= 'string' or data.stage == '') then
    return nil, 'stage must name a card boundary'
  end
  if type(data.module) ~= 'string' or not data.module:match('^[%w_][%w_/%-]*$')
    or data.module:find('//', 1, true) or data.module:sub(-1) == '/' then
    return nil, 'module must be a require-only Lua part path without an extension'
  end
  if not FS:fileExists('/lua/ge/extensions/' .. data.module .. '.lua') then
    return nil, 'contributor part file not found'
  end
  return {id = data.id, order = data.order, module = data.module, pendingField = data.pendingField, stage = data.stage}
end

local function contributors(directory)
  -- Fresh VFS discovery lets a removed or newly mounted owner change the next start or card build.
  return manifests.scan({dir = directory, tag = LOG_TAG, validate = validateContributor})
end

local function loadContributor(entry, method)
  local loaded, part = pcall(require, entry.module)
  if not loaded then
    log('W', LOG_TAG, 'Ignoring contributor ' .. entry.id .. ': ' .. tostring(part))
    return nil
  end
  if type(part) ~= 'table' or type(part[method]) ~= 'function' then
    log('W', LOG_TAG, 'Ignoring contributor ' .. entry.id .. ': missing ' .. method .. ' function')
    return nil
  end
  return part
end

function M.writeStartDefaults(start, savePath)
  for _, entry in ipairs((contributors(START_DEFAULTS_DIR))) do
    local part = not entry.pendingField and loadContributor(entry, 'write')
    if part then
      local called, result, reason = pcall(part.write, start, savePath)
      if not called or result == false then
        local message = not called and tostring(result) or tostring(reason or 'start defaults refused')
        log('E', LOG_TAG, 'Contributor ' .. entry.id .. ' refused career start: ' .. message)
        return false, message
      end
    end
  end
  return true
end

-- Choice writers run between their existing publications; their writer return was always ignored.
function M.writePendingDefault(field, start, savePath, source)
  for _, entry in ipairs((contributors(START_DEFAULTS_DIR))) do
    if entry.pendingField == field then
      require(entry.module).write(start, savePath, source)
    end
  end
end

-- Read owner inputs together at the old disk-read boundary, in manifest order.
function M.readProfileInputs(savePath)
  local saved = {}
  for _, entry in ipairs((contributors(PROFILE_CARDS_DIR))) do
    local part = loadContributor(entry, 'read')
    if part and part.readSaved then saved[entry.id] = part.readSaved(savePath) end
  end
  return saved
end

function M.contributeProfileCard(card, profile, savePath, options)
  for _, entry in ipairs((contributors(PROFILE_CARDS_DIR))) do
    local part = entry.stage == (options and options.stage) and loadContributor(entry, 'read')
    if part then
      local read, fields = pcall(part.read, profile, savePath, options)
      if read and type(fields) == 'table' then
        for key, value in pairs(fields) do card[key] = value end
      else
        local message = read and 'reader must return a table of card fields' or tostring(fields)
        log('W', LOG_TAG, 'Ignoring contributor ' .. entry.id .. ': ' .. message)
      end
    end
  end
  return card
end

return M
