-- Constants and name helpers shared by every part of the save importer (shell/saveImport.lua).
-- Stateless: every function takes its inputs and returns a value.
local M = {}

M.SOURCE_ROOT = 'settings/cloud/saves/'
M.TARGET_ROOT = 'settings/cloud/overhaul/saves/'
-- Written last: its presence with complete = true makes a repeat import recognise the profile.
M.RECORD = 'overhaulImport.json'
M.REPORT = 'overhaulImportReport.json'
M.VERSION = 1
M.PART_RENAME_MARKER = 'career/rls_career/partRenames040.json'

function M.normalized(value)
  return value:gsub('\\', '/'):gsub('^/+', ''):gsub('/+$', '')
end

-- Older Linux saves may contain lowercase basenames. Only canonicalise files the
-- importer or option owners consume; profile names, vehicle ids and arbitrary mod files keep their case.
local savePaths = {}
for _, file in ipairs({
  'career/playerAttributes.json', 'career/partInventory.json', 'career/attributeLog.json',
  M.PART_RENAME_MARKER, 'career/rls_career/logisticsEmployment.json',
  'career/rls_career/legacyMigration.json', 'career/rls_career/legacyMigrationReport.json',
  'career/rls_career/negotiationCooldowns.json', 'career/rls_career/purchasedGarages.json',
  'career/rls_career/realEstateListings.json', 'career/rls_career/realEstateNegotiationState.json',
  'career/rls_career/difficultyMode.json', 'career/rls_career/logisticsEmploymentMode.json',
  'career/rls_career/sandboxXpProfile.json', 'career/rls_career/sandboxEconomyProfile.json',
  'career/rls_career/policePreference.json', 'career/rls_career/maintenanceMode.json',
  'career/rls_career/careerStartMode.json',
}) do savePaths[file:lower()] = file end

function M.canonicalSavePath(file)
  return savePaths[file:lower()] or file
end

-- Read the actual source filename without relying on the host OS ignoring case.
-- Two matching spellings are ambiguous, even when one exactly matches the request.
function M.sourceJson(file)
  return require('overhaul/lib/save/sourcePaths').readJson(file)
end

-- A profile or slot name that is safe to use as a single folder name on every platform.
function M.validName(value)
  if type(value) ~= 'string' or value == '' or value == '.' or value == '..'
    or value:find('[/\\%c<>:"|?*]') or value:find('[%. ]$') then return false end
  local base = value:upper():match('^[^.]+') or ''
  return base ~= 'CON' and base ~= 'PRN' and base ~= 'AUX' and base ~= 'NUL'
    and not base:match('^COM[1-9]$') and not base:match('^LPT[1-9]$')
end

function M.sortedKeys(value)
  local result = {}
  for key in pairs(value) do result[#result + 1] = key end
  table.sort(result, function(a, b) return tostring(a) < tostring(b) end)
  return result
end

return M
