-- Profile-screen view of the RLS saves the importer can copy. Read-only: nothing here writes files.
-- create(deps) returns one instance per importer load; deps are the importer's own functions (list, stamp, ...).
local M = {}

local timing = require('overhaul/lib/ui/profileScreenTiming')
local frameBudgetJob = require('overhaul/lib/ui/frameBudgetJob')

-- The async card list's reply event: {requestId, cards, error}.
local CARDS_EVENT = 'OverhaulImportSourceCards'
-- '/' never occurs in a profile name, so ids cannot collide.
local SOURCE_ID_PREFIX = 'rls/'

-- The rows are kept until the save roots, a profile's slots or an import change them (see invalidate).
-- generation counts invalidations, so an async scan started before one never stores stale rows.
local function newCache()
  return {rows = nil, stamp = nil, slotStamps = {}, highlights = {}, generation = 0}
end

local function invalidate(importer)
  importer.cache.rows, importer.cache.stamp, importer.cache.slotStamps, importer.cache.highlights = nil, nil, {}, {}
  importer.cache.generation = importer.cache.generation + 1
end

-- One profile's slots as the scan saw them: which slots, their save dates and versions.
local function slotStamp(found)
  local parts = {}
  for _, slot in ipairs(found) do
    parts[#parts + 1] = slot.name .. '@' .. tostring(slot.info.date) .. '@' .. tostring(slot.info.version)
  end
  return table.concat(parts, '|')
end

-- Scans every RLS profile and keeps each one's slotStamp; pace() is optional and called per profile.
local function scanProfiles(importer, pace)
  local slotStamps = {}
  local rows = importer.deps.list(function(profile, found)
    slotStamps[profile] = slotStamp(found)
    if pace then pace() end
  end)
  return rows, slotStamps
end

-- The cached rows, rescanned when a profile folder appeared or went, or when the asked-for profile's
-- slots no longer match the scan (a restored backup, a newer autosave).
local function sourceRows(importer, profile)
  local cache = importer.cache
  local stamp = importer.deps.stamp()
  local fresh = cache.rows and cache.stamp == stamp
  if fresh and profile and (cache.slotStamps[profile] or '') ~= slotStamp(importer.deps.slots(profile)) then fresh = false end
  if fresh then return cache.rows end
  cache.highlights = {}
  cache.rows, cache.slotStamps = scanProfiles(importer)
  cache.stamp = stamp
  return cache.rows
end

local function sourceRow(importer, profile)
  for _, row in ipairs(sourceRows(importer, profile)) do
    if row.profileName == profile then return row end
  end
end

-- The copy's name when the player keeps the suggestion: executeImport's own default.
local function defaultTarget(importer, profile)
  for _, record in ipairs(importer.deps.records()) do
    if record.sourceProfile == profile and record.defaultTarget == true then return record.targetProfile end
  end
  local target, suffix = profile, 2
  while FS:directoryExists(importer.deps.targetRoot .. target) do target = profile .. ' ' .. suffix; suffix = suffix + 1 end
  return target
end

-- The card from the career's own formatter, or a plain card when the formatter fails.
local function importSourceCard(importer, career, row)
  local ok, value = pcall(career and career.formatImportSourceCard, row.profileName, importer.deps.sourceRoot .. row.profileName .. '/' .. row.slot)
  local card
  if ok and type(value) == 'table' then card = value end
  card = card or {money = {value = row.money}, vehicleCount = row.vehicleCount, date = row.lastPlayed, version = row.version}
  card.id = SOURCE_ID_PREFIX .. row.profileName
  card.importSource, card.sourceProfile = true, row.profileName
  card.displayName = row.displayName
  card.importGameVersion, card.canImport, card.blockedSlots = row.gameVersion, row.canImport, row.blockedSlots
  card.importBlockReason = row.importBlockReason
  card.requiresMigration = row.gameVersion == '0.39'
  card.outdatedVersion = card.requiresMigration
  return card
end

-- Profile-screen cards for RLS saves not imported yet; `pace` (optional) is called after each card.
local function buildCards(importer, rows, pace)
  local cards = {}
  local career = overhaul_career_career
  for _, row in ipairs(rows) do
    if not row.alreadyImported then
      cards[#cards + 1] = importSourceCard(importer, career, row)
      if pace then pace() end
    end
  end
  return cards
end

-- Always a fresh scan: this is the screen's list refresh.
local function getCards(importer)
  local span = timing.start('importSourceCards')
  invalidate(importer)
  local rows = sourceRows(importer)
  timing.step(span, 'scan')
  local cards = buildCards(importer, rows)
  timing.step(span, 'cards')
  timing.finish(span, 'sources=' .. #rows .. ' cards=' .. #cards)
  return cards
end

-- Scans and builds the cards, storing the rows only when no invalidation happened during the scan.
local function scanAndBuildCards(importer, generation, span, pace)
  local stamp = importer.deps.stamp()
  local rows, slotStamps = scanProfiles(importer, pace)
  timing.step(span, 'scan')
  if importer.cache.generation == generation then
    importer.cache.rows, importer.cache.slotStamps, importer.cache.stamp = rows, slotStamps, stamp
  end
  return buildCards(importer, rows, pace)
end

-- Builds the cards in frame-sized steps, then sends the reply unless the importer was unloaded meanwhile.
local function replyWithCards(importer, generation, requestId, screen, pace)
  if importer.retired then return end
  local span = timing.start('importSourceCardsAsync')
  local function paceUnlessRetired() -- checked again after the pause, as for profile lists
    if importer.retired then error('the importer was unloaded') end
    pace()
    if importer.retired then error('the importer was unloaded') end
  end
  local ok, cards = pcall(scanAndBuildCards, importer, generation, span, paceUnlessRetired)
  timing.step(span, 'cards')
  timing.finish(span, ok and ('cards=' .. #cards) or 'failed')
  if importer.retired then return end
  if not ok then log('E', 'importSources', 'RLS import cards failed: ' .. tostring(cards)) end
  guihooks.trigger(CARDS_EVENT, {requestId = requestId, screen = screen, cards = ok and cards or {},
    error = not ok and tostring(cards) or nil})
end

-- Pace card scans across frames and echo request/screen identity so stale replies cannot replace a newer screen.
local function getCardsAsync(importer, requestId, screen)
  invalidate(importer)
  local generation = importer.cache.generation
  frameBudgetJob.run(function(pace) replyWithCards(importer, generation, requestId, screen, pace) end)
  return true
end

local function stripSourcePrefix(id)
  if type(id) == 'string' and id:sub(1, #SOURCE_ID_PREFIX) == SOURCE_ID_PREFIX then return id:sub(#SOURCE_ID_PREFIX + 1) end
  return id
end

local function blockedPreflight(profile, title, detail)
  return {schemaVersion = 1, profile = profile, importSource = true, requiresMigration = true, canMigrate = false,
    blockerCount = 1, actionCount = 0, warningCount = 0, vehicles = {}, garages = {},
    issues = {{severity = 'blocker', code = 'import.unavailable', title = title, detail = detail}}}
end

-- Marks the importer's report as an import of `profile` (0.39 saves offer main's vehicle choices).
local function markPreflight(importer, report, profile, row)
  local isLegacy = row.gameVersion == '0.39'
  report.importSource, report.sourceProfile, report.id = true, profile, SOURCE_ID_PREFIX .. profile
  report.displayName = row.displayName
  report.legacySource, report.policyChoice = isLegacy, isLegacy
  report.requiresMigration, report.preparedMigration = true, false
  report.defaultTargetProfile = defaultTarget(importer, profile)
  if not isLegacy then report.migrationLabel = 'RLS save → Overhaul' end
  if not row.canImport then
    report.canMigrate = false
    report.blockerCount = (report.blockerCount or 0) + 1
    report.issues = type(report.issues) == 'table' and report.issues or {}
    table.insert(report.issues, 1, {severity = 'blocker', code = 'import.blockedSlots',
      title = 'Some save slots cannot be imported',
      detail = row.importBlockReason or ('Unsupported or damaged slots: ' .. table.concat(row.blockedSlots or {}, ', ') .. '.')})
  elseif row.skippedSlotReason then
    report.warningCount = (report.warningCount or 0) + 1
    report.issues = type(report.issues) == 'table' and report.issues or {}
    table.insert(report.issues, {severity = 'warning', code = 'import.skippedSlots',
      title = 'Some save slots will be skipped', detail = row.skippedSlotReason})
  end
end

-- The migration step's report for a source card: main's preflight of its newest slot, marked as an import.
-- A current RLS save was never migrated on main, so it is copied as it is.
local function getPreflight(importer, profile)
  local deps = importer.deps
  profile = stripSourcePrefix(profile)
  if not deps.validName(profile) then return blockedPreflight(profile, 'Save data was not found', 'Invalid source profile name.') end
  local row
  for _, candidate in ipairs(deps.list(nil, profile)) do row = candidate end
  if not row then return blockedPreflight(profile, 'Save data was not found', 'No readable RLS save slot could be selected.') end
  if not row.canImport then
    local report = {schemaVersion = 1, profile = profile, sourceVersion = row.version, targetVersion = 64,
      canMigrate = false, blockerCount = 0, actionCount = 0, warningCount = 0, vehicles = {}, garages = {}, issues = {}}
    markPreflight(importer, report, profile, row)
    return report
  end
  local slot
  for _, candidate in ipairs(deps.slots(profile)) do
    if candidate.name == row.slot then slot = candidate end
  end
  local ok, report = pcall(deps.preflight, profile, slot)
  if not ok then return blockedPreflight(profile, 'Save data was not found', tostring(report)) end
  markPreflight(importer, report, profile, row)
  return report
end

-- The hero card's recent money and asset value, as for an Overhaul profile. Asked each time the player
-- moves onto a source card, so the answer is kept with the rows.
local function getHighlights(importer, id, limit)
  local span = timing.start('importSourceHighlights')
  local profile = stripSourcePrefix(id)
  local career = overhaul_career_career
  local row = importer.deps.validName(profile) and sourceRow(importer, profile)
  timing.step(span, 'rows')
  if not row then return {recentMoney = {}, assetValue = 0} end
  local key = profile .. '|' .. tostring(limit)
  local highlights = importer.cache.highlights[key]
  if highlights == nil then
    highlights = career.getImportSourceHighlights(profile, importer.deps.sourceRoot .. profile .. '/' .. row.slot, limit)
    importer.cache.highlights[key] = highlights
  end
  timing.step(span, 'highlights')
  timing.finish(span, profile)
  return highlights
end

function M.create(deps)
  local importer = {deps = deps, cache = newCache(), retired = false}
  return {
    cards = function() return getCards(importer) end,
    cardsAsync = function(requestId, screen) return getCardsAsync(importer, requestId, screen) end,
    preflight = function(profile) return getPreflight(importer, profile) end,
    highlights = function(id, limit) return getHighlights(importer, id, limit) end,
    defaultTarget = function(profile) return defaultTarget(importer, profile) end,
    invalidate = function() invalidate(importer) end,
    dispose = function() importer.retired = true end,
  }
end

return M
