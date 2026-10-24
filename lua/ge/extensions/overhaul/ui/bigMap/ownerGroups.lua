-- Big-map owner metadata: validation, snapshot loading and ordered UI projections.
-- The catalog owns discovery; optional map metadata cannot change shell adoption.
local owners = require('overhaul/lib/career/manifest')
local manifests = require('overhaul/lib/platform/manifests')
local M = {}

local MODES = {career = true, freeroam = true}
local FREEROAM_POIS_SECTION = 'freeroamPois'
local RESERVED_SECTION_IDS = {freeroamPois = true, everything = true, tutorialLessonsBySection = true}

local function finite(value)
  return type(value) == 'number' and value == value and math.abs(value) ~= math.huge
end

local function isArray(value)
  if type(value) ~= 'table' then return false end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then return false end
    count = count + 1
  end
  return count == #value
end

local function modes(value)
  if value == nil then return true end
  if not manifests.isStringList(value) then return false end
  for _, mode in ipairs(value) do
    if not MODES[mode] then return false end
  end
  return true
end

-- A missing list means every mode; a list restricts the row to the modes it names.
local function enabled(value, mode)
  if value == nil then return true end
  for _, entry in ipairs(value) do
    if entry == mode then return true end
  end
  return false
end

local function warn(owner, reason)
  log('W', 'overhaul_bigmap_owners', owner .. ': ' .. reason)
end

-- Returns the first failing row's reason, so bad metadata reports the same message as before.
local function checkRows(rows, checkRow)
  for _, row in ipairs(rows or {}) do
    local valid, reason = checkRow(row)
    if not valid then return false, reason end
  end
  return true
end

local function validPoiType(row)
  if type(row) ~= 'table' or not manifests.isNonEmptyString(row.id)
    or not row.id:match('^[%a][%w_]*$') then
    return false, 'invalid POI type'
  end
  if row.tags ~= nil and (not isArray(row.tags) or not manifests.isStringList(row.tags)) then
    return false, 'tags must be a non-empty string list'
  end
  if row.icon ~= nil and not manifests.isNonEmptyString(row.icon) then return false, 'invalid type icon' end
  return true
end

local function validPlacements(placementsByMode)
  if type(placementsByMode) ~= 'table' then return false, 'group placements must be an object' end
  for mode, placements in pairs(placementsByMode) do
    if not MODES[mode] or not isArray(placements) then return false, 'invalid placement mode or list' end
    for _, placement in ipairs(placements) do
      if type(placement) ~= 'table' or not manifests.isNonEmptyString(placement.section)
        or not finite(placement.order) then
        return false, 'placement needs section and finite order'
      end
    end
  end
  return true
end

local function validGroup(row)
  if type(row) ~= 'table' or not manifests.isNonEmptyString(row.id)
    or not manifests.isNonEmptyString(row.label) or not modes(row.modes)
    or (row.icon ~= nil and not manifests.isNonEmptyString(row.icon))
    or (row.hideFromMap ~= nil and type(row.hideFromMap) ~= 'boolean') then
    return false, 'invalid group metadata'
  end
  return validPlacements(row.placements)
end

local function validSection(row)
  if type(row) ~= 'table' or not manifests.isNonEmptyString(row.id)
    or not manifests.isNonEmptyString(row.title) or not manifests.isNonEmptyString(row.icon)
    or not finite(row.order) or not modes(row.modes) then
    return false, 'invalid section metadata'
  end
  if RESERVED_SECTION_IDS[row.id] or row.id:sub(1, 7) == 'domain_' then
    return false, 'section id is reserved by the map'
  end
  return true
end

function M.validate(data)
  if type(data) ~= 'table' then return false, 'bigMap must be an object' end
  for _, field in ipairs({'types', 'groups', 'sections'}) do
    if data[field] ~= nil and not isArray(data[field]) then return false, field .. ' must be a list' end
  end
  local valid, reason = checkRows(data.types, validPoiType)
  if not valid then return false, reason end
  valid, reason = checkRows(data.groups, validGroup)
  if not valid then return false, reason end
  return checkRows(data.sections, validSection)
end

-- First catalog owner wins a colliding map id; the loser is warned about and skipped.
local function adopt(target, rows, owner, category)
  for _, row in ipairs(rows or {}) do
    if target[row.id] then
      warn(owner, 'duplicate ' .. category .. ' ' .. row.id .. '; first catalog owner wins')
    else
      row.owner = owner
      target[row.id] = row
    end
  end
end

-- scanOwners strips map fields, so the accepted owner file is reread for its bigMap block.
local function readOwnerMetadata(owner)
  local data = jsonReadFile(owners.ownersDir .. owner.id .. '.json')
  if type(data) == 'table' then return data.bigMap end
end

local function adoptOwnerMetadata(snapshot, owner, metadata)
  local valid, reason = M.validate(metadata)
  if not valid then
    warn(owner.id, reason)
    return
  end
  adopt(snapshot.types, metadata.types, owner.id, 'POI type')
  adopt(snapshot.groups, metadata.groups, owner.id, 'group')
  adopt(snapshot.sections, metadata.sections, owner.id, 'section')
end

-- An overridden or rejected map owner must not strand unregistered POIs outside the filter UI.
local function ensureCatchallGroup(snapshot)
  if snapshot.groups.type_other then return end
  warn('bigMap', 'missing catchall declaration; preserving the Other filter')
  snapshot.groups.type_other = {id = 'type_other', label = 'Other', icon = 'info', hideFromMap = true,
    placements = {
      career = {{section = FREEROAM_POIS_SECTION, order = math.huge}},
      freeroam = {{section = FREEROAM_POIS_SECTION, order = math.huge}},
    }}
end

-- A type whose tag names no declared group is dropped, so its POIs fall back to the catchall.
local function dropUndeclaredTypes(snapshot)
  for id, row in pairs(snapshot.types) do
    row.tags = row.tags or {'type_' .. id}
    for _, tag in ipairs(row.tags) do
      if not snapshot.groups[tag] then
        warn(row.owner, 'POI type ' .. id .. ' references undeclared group ' .. tag .. '; using the catchall')
        snapshot.types[id] = nil
        break
      end
    end
  end
end

-- A fresh snapshot per map cache/adoption. Same-path overrides and rejected owners follow
-- scanOwners; first catalog owner wins colliding map ids. Bad metadata affects only the map.
function M.load()
  local snapshot = {types = {}, groups = {}, sections = {}}
  for _, owner in ipairs((owners.scanOwners())) do
    local metadata = readOwnerMetadata(owner)
    if metadata ~= nil then adoptOwnerMetadata(snapshot, owner, metadata) end
  end
  ensureCatchallGroup(snapshot)
  dropUndeclaredTypes(snapshot)
  return snapshot
end

function M.groupData(snapshot, mode)
  local groups = {}
  for id, row in pairs(snapshot.groups) do
    if enabled(row.modes, mode) then
      groups[id] = {label = row.label, icon = row.icon, hideFromMap = row.hideFromMap}
    end
  end
  return groups
end

-- Groups placed in a section for this mode, ordered by placement order then id.
function M.sectionGroups(snapshot, mode, section, groups)
  local rows = {}
  for id, row in pairs(snapshot.groups) do
    if groups[id] and enabled(row.modes, mode) then
      for _, placement in ipairs(row.placements[mode] or {}) do
        if placement.section == section then rows[#rows + 1] = {id = id, order = placement.order} end
      end
    end
  end
  table.sort(rows, manifests.byOrderThenId)
  local result = {}
  for _, row in ipairs(rows) do result[#result + 1] = groups[row.id] end
  return result
end

function M.extraSections(snapshot, mode, groups)
  local rows = {}
  for _, row in pairs(snapshot.sections) do
    if enabled(row.modes, mode) then rows[#rows + 1] = row end
  end
  table.sort(rows, manifests.byOrderThenId)
  local result = {}
  for _, row in ipairs(rows) do
    result[#result + 1] = {key = row.id, icon = row.icon, title = row.title,
      groups = M.sectionGroups(snapshot, mode, row.id, groups)}
  end
  return result
end

return M
