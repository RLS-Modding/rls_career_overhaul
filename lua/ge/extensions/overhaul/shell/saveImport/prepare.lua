-- Prepares imported profiles in memory: layout migration, saved-name rewrites and per-slot conservation.
-- Each slot keeps its money and vehicles unless the caller selects the explicit legacy cash-out plan.
local names = require('overhaul/shell/saveImport/names')
local levelData = require('overhaul/lib/world/levelData')
local partMigration = require("overhaul/lib/save/partMigration040")
local shapes = require("overhaul/lib/save/migrationShapes")
local cashOut = require('overhaul/shell/saveImport/cashOut')
local saveSchema = require('overhaul/lib/save/schema')

local M = {}

-- Config ------------------------------------------------------------------------------------------

local PART_RENAME_VERSION = 3
local EXTENSION_NAMES_PATH = '/gameplay/overhaul/save/importExtensionNames.json'
local FILE_PATHS_PATH = '/gameplay/overhaul/save/importFilePaths.json'
local IMPORTED_SAVINGS_RATE_PER_SECOND = 0.05 / (6 * 3600)

-- State -------------------------------------------------------------------------------------------

-- Set only while migrate runs, so warnings collect into that call's list.
local partMigrationWarnings
local extensionNameAliases, filePathAliases

-- Layout migration -------------------------------------------------------------------------------


local function partMigrationWarning(message)
  if partMigrationWarnings then partMigrationWarnings[#partMigrationWarnings + 1] = message end
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, child in pairs(value) do result[key] = copy(child) end
  return result
end

local function read(files, file)
  local entry = files[file]
  return type(entry) == "table" and copy(entry.data) or nil
end

local function write(files, file, data)
  local entry = type(files[file]) == "table" and files[file] or {}
  entry.data, entry.bytes = data, nil
  files[file] = entry
end

local function vehicleFiles(files)
  local result = {}
  for file in pairs(files) do
    if type(file) == "string" and file:match("^career/vehicles/[^/]+%.json$") then result[#result + 1] = file end
  end
  table.sort(result)
  return result
end

-- Rebuilds the insurance file's per-vehicle rows from the vehicle files, keyed by inventory id.
local function preprocessInsurance(files, vehicles)
  local oldData = read(files, "career/insurance.json")
  if type(oldData) ~= "table" then oldData = {} end
  local oldInvVehs = type(oldData.invVehs) == "table" and oldData.invVehs or {}
  local newInvVehs = {}
  for _, file in ipairs(vehicles) do
    local inventoryId = tonumber(file:match("([%d]+)%.json$"))
    if inventoryId then
      local vehicle = read(files, file)
      if type(vehicle) == "table" then
        newInvVehs[inventoryId] = shapes.ensureInvVehShape(shapes.lookupOldInvVeh(oldInvVehs, inventoryId), inventoryId, vehicle)
      end
    end
  end
  write(files, "career/insurance.json", shapes.insuranceData(oldData, newInvVehs))
end

local function readPartInventory(files, inventoryPath)
  local inventoryJson = read(files, inventoryPath)
  if not files[inventoryPath] then return {} end
  if type(inventoryJson) ~= "table" or type(inventoryJson[1]) ~= "string" then error("Unreadable part inventory") end
  local inventory = deserialize(inventoryJson[1])
  if type(inventory) ~= "table" then error("Unreadable part inventory") end
  return inventory
end

-- Renames the parts of every vehicle and the loose part inventory, then records the layout marker.
local function runPartRenames(files, vehicles, summary)
  local marker = read(files, names.PART_RENAME_MARKER)
  if type(marker) == "table" and (tonumber(marker.version) or 0) >= PART_RENAME_VERSION then return end
  local inventoryPath = "career/partInventory.json"
  local inventory = readPartInventory(files, inventoryPath)
  local originalInventory = serialize(inventory)
  local beforeInventory = copy(inventory)
  for _, file in ipairs(vehicles) do
    local vehicle = read(files, file)
    if type(vehicle) ~= "table" then error("Unreadable vehicle record: " .. file) end
    vehicle.id = vehicle.id or tonumber(file:match("(%d+)%.json$"))
    if partMigration.migrateVehicleParts040(vehicle, inventory, partMigrationWarning) then
      write(files, file, vehicle)
      summary.vehiclesMigrated = summary.vehiclesMigrated + 1
    end
  end
  partMigration.migrateLooseParts040(inventory, partMigrationWarning)
  shapes.countPartChanges(inventory, beforeInventory, summary)
  local inventoryData = serialize(inventory)
  if inventoryData ~= originalInventory then write(files, inventoryPath, {inventoryData}) end
  write(files, names.PART_RENAME_MARKER, {version = PART_RENAME_VERSION})
  summary.layoutMigrated = true
end

local function checkInputs(files, sourceVersion)
  if type(files) ~= "table" then return {ok = false, error = "Save files must be an in-memory table."} end
  if not sourceVersion or sourceVersion % 1 ~= 0 or sourceVersion < 36 or sourceVersion > 64 then
    return {ok = false, error = "Save version is outside the supported range (36-64)."}
  end
  return nil
end

-- Runs every migration step on the staged copy; an error here leaves the caller's files untouched.
local function migrateCopy(staged, info, sourceVersion, summary)
  local vehicles = vehicleFiles(staged)
  if sourceVersion < 64 then
    preprocessInsurance(staged, vehicles)
    summary.insuranceMigrated = true
  end
  runPartRenames(staged, vehicles, summary)
  info.version = 64
  write(staged, "info.json", info)
end

-- Returns {ok, summary, warnings}, or {ok = false, error}. `files` is updated in place on success.
function M.migrate(files, sourceVersion)
  sourceVersion = tonumber(sourceVersion)
  local invalid = checkInputs(files, sourceVersion)
  if invalid then return invalid end
  local info = read(files, "info.json")
  if type(info) ~= "table" then return {ok = false, error = "Save info.json is unreadable."} end
  local warnings = {}
  local summary = {
    sourceVersion = sourceVersion, targetVersion = 64, targetLayoutVersion = PART_RENAME_VERSION,
    vehiclesMigrated = 0, partsMigrated = 0, itemsMovedToInventory = 0,
    insuranceMigrated = false, layoutMigrated = false, warnings = warnings,
  }
  local marker = read(files, names.PART_RENAME_MARKER)
  if sourceVersion == 64 and type(marker) == "table" and (tonumber(marker.version) or 0) >= PART_RENAME_VERSION then
    return {ok = true, summary = summary, warnings = warnings}
  end
  local staged = copy(files)
  partMigrationWarnings = warnings
  local ok, result = pcall(migrateCopy, staged, info, sourceVersion, summary)
  partMigrationWarnings = nil
  if not ok then return {ok = false, error = tostring(result)} end
  for file, entry in pairs(staged) do files[file] = entry end
  return {ok = true, summary = summary, warnings = warnings}
end

-- Saved names -----------------------------------------------------------------------------------


-- A missing alias table must fail the import rather than silently skip an entire class of renames.
local function readAliases(path)
  local data = jsonReadFile(path)
  assert(type(data) == 'table' and type(data.aliases) == 'table', 'Missing save import alias table: ' .. path)
  return data.aliases
end


-- Maps a profile's own folder path to the target folder, keeping the part after it.
local function renameProfilePath(forward, profile, target)
  local source = names.SOURCE_ROOT .. profile .. '/'
  local start = forward:find(source, 1, true)
  if start and (start == 1 or forward:sub(start - 1, start - 1) == '/') then
    return names.TARGET_ROOT .. target .. '/' .. forward:sub(start + #source)
  end
  if forward == names.SOURCE_ROOT .. profile then return names.TARGET_ROOT .. target end
end

-- Moves the game folders and the old settings folder to their Overhaul names, then applies the file path table.
local function renameGamePath(value)
  local renamed = value:gsub('\\', '/')
    :gsub('^(/?)lua/ge/extensions/career/', '%1lua/ge/extensions/overhaul/career/')
    :gsub('^(/?)gameplay/(domains/)', '%1gameplay/overhaul/%2')
    :gsub('^(/?)gameplay/(organizations/)', '%1gameplay/overhaul/%2')
    :gsub('^(/?)gameplay/(insurance/)', '%1gameplay/overhaul/%2')
    :gsub('^(/?)settings/rls_career/', '%1settings/overhaul/')
  local leading = renamed:sub(1, 1) == '/' and '/' or ''
  renamed = leading .. (filePathAliases[renamed:sub(#leading + 1)] or renamed:sub(#leading + 1))
  return renamed
end

function M.renameString(value, profile, target, scope, aliases)
  extensionNameAliases = extensionNameAliases or readAliases(EXTENSION_NAMES_PATH)
  filePathAliases = filePathAliases or readAliases(FILE_PATHS_PATH)
  value = value:gsub('%f[%w_]career_([%w_]+)', 'overhaul_career_%1')
    :gsub('%f[%w_]onCareer([%w_]+)', 'onOverhaul%1')
  value = extensionNameAliases[value] or value
  value = levelData.renameMapString(value, scope, aliases)
  local forward = value:gsub('\\', '/')
  local profilePath = renameProfilePath(forward, profile, target)
  if profilePath then return profilePath end
  local renamed = renameGamePath(forward)
  return renamed ~= forward and renamed or value
end

local function equal(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= 'table' then return a == b end
  for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

-- Two keys that rename to the same name must hold the same data or tables that merge without conflict.
local function merge(a, b, location)
  if equal(a, b) then return a end
  assert(type(a) == 'table' and type(b) == 'table', 'Rename collision at ' .. location)
  for key, value in pairs(b) do
    if a[key] == nil then a[key] = value else a[key] = merge(a[key], value, location .. '/' .. tostring(key)) end
  end
  return a
end

local function renameData(checkpoint, data, profile, target, location, scope, aliases)
  -- Keep the source file location while recursing so serialized part tables and collision errors retain context.
  local result = {}
  for _, key in ipairs(names.sortedKeys(data)) do
    local value, newKey = data[key], key
    if type(key) == 'string' then newKey = M.renameString(key, profile, target, scope, aliases) end
    if type(value) == 'table' then
      value = renameData(checkpoint, value, profile, target, location .. '/' .. tostring(key), scope, aliases)
    elseif type(value) == 'string' then
      if key == 'partConditions' or (type(key) == 'number' and location:match('partInventory%.json$')) then
        local decoded = deserialize(value)
        assert(type(decoded) == 'table', 'Unreadable serialized save data at ' .. location)
        value = serialize(renameData(checkpoint, decoded, profile, target, location .. '/' .. tostring(key), scope, aliases))
      else
        value = M.renameString(value, profile, target, scope, aliases)
      end
    end
    if result[newKey] ~= nil then result[newKey] = merge(result[newKey], value, location)
    else result[newKey] = value end
    checkpoint(nil, nil, 1 / 128)
  end
  return result
end

-- Conservation totals ---------------------------------------------------------------------------

-- What an old profile holds, summed so the importer can prove it lost nothing: money in every place it can
-- sit, and the vehicle counts and value. Compared before and after a slot is renamed and migrated.
local function payload(files, name)
  return files[name] and files[name].data
end

local function addBankTotals(result, bank)
  for key, account in pairs(bank.accounts or {}) do
    result.accounts[tostring(account.id or key)] = account.balance or 0
    if account.type == 'personal' and account.accountType == 'savings' then
      result.savingsInterest = result.savingsInterest + (account.accruedInterest or 0)
        + (account.segmentBalance or account.balance or 0) * IMPORTED_SAVINGS_RATE_PER_SECOND * math.max(0, account.sinceSegmentStart or 0)
    end
  end
  for _, transfer in pairs(bank.pendingTransfers or {}) do
    assert(type(transfer.amount) == 'number' and transfer.amount >= 0, 'Invalid pending bank transfer')
    result.pendingTransfers = result.pendingTransfers + transfer.amount
  end
end

-- Escrow held by the logistics employment, in one record per employer or in the older single record.
local function addEscrowTotals(result, employment)
  for _, emp in pairs(employment.employments or {}) do result.escrow = result.escrow + (emp.escrow and emp.escrow.money or 0) end
  if not employment.employments then result.escrow = employment.escrow and employment.escrow.money or 0 end
end

local function addVehicleTotals(result, files)
  for name, entry in pairs(files) do
    if name:match('^career/vehicles/[^/]+%.json$') then
      result.vehicleCount = result.vehicleCount + 1
      if entry.data.owned ~= false then result.ownedVehicleCount = result.ownedVehicleCount + 1 end
      result.vehicleValue = result.vehicleValue + (tonumber(entry.data.configBaseValue) or 0)
    elseif name:match('^career/rls_career/businesses/[^/]+/vehicles/[^/]+%.json$') then
      result.businessVehicleCount = result.businessVehicleCount + 1
    elseif name:match('^career/rls_career/businesses/[^/]+/vehicles%.json$') then
      for _ in pairs(entry.data.vehicles or {}) do result.businessVehicleCount = result.businessVehicleCount + 1 end
    end
  end
end

local function sumTotals(files)
  local attributes = assert(payload(files, 'career/playerAttributes.json'), 'Missing player attributes')
  assert(type(attributes.money) == 'table' and type(attributes.money.value) == 'number', 'Missing wallet balance')
  local result = {wallet = attributes.money.value, accounts = {}, pendingTransfers = 0, vehicleCount = 0,
    ownedVehicleCount = 0, vehicleValue = 0, businessVehicleCount = 0, escrow = 0, savingsInterest = 0}
  addBankTotals(result, payload(files, 'career/rls_career/bank.json') or {})
  addEscrowTotals(result, payload(files, 'career/rls_career/logisticsEmployment.json') or {})
  addVehicleTotals(result, files)
  result.moneyTotal = result.wallet + result.pendingTransfers + result.escrow + result.savingsInterest
  for _, balance in pairs(result.accounts) do result.moneyTotal = result.moneyTotal + balance end
  return result
end

-- Cancel unapplied legacy cash-out so imported vehicles and garages remain owned by the player.
local function settleLegacyPlan(files, report)
  local legacyPlan = payload(files, 'career/rls_career/legacyMigration.json')
  if legacyPlan and legacyPlan.status ~= 'applied' then
    legacyPlan.status = 'applied'
    report.actions[#report.actions + 1] = {policy = 'cancelLegacyCashOut', amount = 0,
      retainedVehicleIds = legacyPlan.cashOutVehicleIds or {}, retainedGarageIds = legacyPlan.cashOutGarageIds or {}}
  end
end

-- Warns about retained vehicle models that are no longer installed, in file-name order.
local function warnMissingModels(slotFiles, detail)
  for _, name in ipairs(names.sortedKeys(slotFiles)) do
    local entry = slotFiles[name]
    if name:match('^career/vehicles/[^/]+%.json$') and type(entry.data.model) == 'string'
      and not FS:directoryExists('/vehicles/' .. entry.data.model .. '/') then
      detail.warnings[#detail.warnings + 1] = 'Missing model retained: ' .. entry.data.model .. ' (' .. name .. ')'
    end
  end
end

-- Checks that the renamed slot kept its money and its vehicles.
local function assertConserved(detail, baseline)
  assert(math.abs(detail.after.moneyTotal - baseline.moneyTotal) < 0.00001, 'Money conservation check failed')
  assert(detail.after.vehicleCount == baseline.vehicleCount and detail.after.ownedVehicleCount == baseline.ownedVehicleCount
    and detail.after.businessVehicleCount == baseline.businessVehicleCount and detail.after.vehicleValue == baseline.vehicleValue,
    'Vehicle conservation check failed')
end

-- Renames a staged slot's files into the output and checks that no money or vehicle was lost.
local function finishSlot(helpers, run, item, index)
  local profile, target, report, output = run.profile, run.target, run.report, run.output
  local slot, slotFiles, detail, baseline = item.slot, item.files, item.detail, item.baseline
  local prefix = slot.name .. '/'
  warnMissingModels(slotFiles, detail)
  local info = payload(slotFiles, 'info.json')
  info.displayName = target
  info.overhaulSchema = saveSchema.OVERHAUL_SCHEMA
  for name, entry in pairs(slotFiles) do
    if entry.data then entry.data = helpers.renameData(entry.data, profile, target, name, item.scope, item.aliases) end
    local newName = levelData.renameMapFile(name, item.scope, item.aliases)
    assert(not output[prefix .. newName], 'Save filename collision: ' .. newName)
    output[prefix .. newName] = entry
    helpers.checkpoint()
  end
  detail.after = sumTotals(slotFiles)
  assertConserved(detail, baseline)
  report.slots[#report.slots + 1] = detail
  helpers.checkpoint('preparing', 0.4 + 0.28 * index / #run.sourceSlots, 0, true)
end

-- The slot's files, keyed by their path inside the slot folder.
local function slotFilesOf(helpers, files, slot)
  local slotFiles, prefix = {}, slot.name .. '/'
  for name, entry in pairs(files) do
    if name:sub(1, #prefix) == prefix then slotFiles[name:sub(#prefix + 1)] = entry end
    helpers.checkpoint(nil, nil, 1 / 128)
  end
  return slotFiles
end

-- Applies the legacy cash-out plan to a slot and checks its money and vehicles; returns the new baseline.
local function applyCashOut(helpers, slotFiles, plan, before, detail)
  local applied, err = cashOut.applyToSlot(slotFiles, plan, 64)
  assert(applied, err)
  local soldCount = #applied.cashOut.appliedVehicleIds
  local baseline = sumTotals(slotFiles)
  local credited = applied.cashOut.totalValue + applied.garageCashOut.garageValue
  assert(math.abs(baseline.moneyTotal - before.moneyTotal - credited) < 0.00001, 'Cash-out money check failed')
  assert(baseline.vehicleCount == before.vehicleCount - soldCount
    and baseline.businessVehicleCount == before.businessVehicleCount, 'Cash-out vehicle check failed')
  detail.cashOut = {vehiclesSold = soldCount, vehicleValue = applied.cashOut.vehicleValue,
    loosePartsSold = applied.cashOut.soldPartCount, partValue = applied.cashOut.partValue,
    garagesSold = #applied.garageCashOut.appliedGarageIds, garageValue = applied.garageCashOut.garageValue,
    amountCredited = credited}
  detail.legacyApplied = applied
  helpers.checkpoint(nil, nil, 0, true)
  return baseline
end

-- Runs the part and layout migration on a slot that predates it and records its summary and warnings.
local function migrateSlotLayout(helpers, slot, slotFiles, plan, detail)
  helpers.checkpoint(nil, nil, 0, true)
  local info = payload(slotFiles, 'info.json')
  local result = M.migrate(slotFiles, plan and tonumber(info.version) or tonumber(slot.info.version))
  assert(result.ok, result.error)
  detail.migration = result.summary
  if plan and detail.legacyApplied.insuranceMigrated then detail.migration.insuranceMigrated = true end
  detail.warnings = result.warnings or {}
  helpers.checkpoint(nil, nil, 0, true)
end

-- Apply legacy cash-out before part layout migration so each staged slot matches the chosen policy.
local function stageSlot(helpers, slot, files, plan)
  local slotFiles = slotFilesOf(helpers, files, slot)
  local before = sumTotals(slotFiles)
  local detail = {slot = slot.name, sourceVersion = tonumber(slot.info.version), before = before, actions = {}, warnings = {}}
  local scope = {saveVersion = detail.sourceVersion, levelId = (payload(slotFiles, 'career/general.json') or {}).level}
  local aliases = levelData.mapAliases(scope)
  local baseline = before
  if plan then baseline = applyCashOut(helpers, slotFiles, plan, before, detail) end
  if helpers.legacy(slot.info, payload(slotFiles, names.PART_RENAME_MARKER)) then
    migrateSlotLayout(helpers, slot, slotFiles, plan, detail)
  end
  settleLegacyPlan(slotFiles, detail)
  return {slot = slot, files = slotFiles, detail = detail, baseline = baseline, scope = scope, aliases = aliases}
end

-- With a plan, every slot gets the primary slot's cash-out manifest, and the report records the plan.
local function writeLegacyManifests(run, staged, plan)
  local primary, layoutReports = staged[1], {}
  for _, item in ipairs(staged) do
    if item.slot.name == plan.report.saveFolder then primary = item end
    layoutReports[item.slot.name] = item.detail.migration
  end
  -- Capture the primary migration result before later slots clear their own results.
  local primaryApplied = assert(primary.detail.legacyApplied, 'The primary save slot was not prepared')
  for _, item in ipairs(staged) do
    cashOut.writeManifest(item.files, plan, primaryApplied, layoutReports, primary.slot.name,
      run.profile, run.target, 64)
  end
  for _, item in ipairs(staged) do item.detail.legacyApplied = nil end
  run.report.legacyMigration = {vehiclePolicy = plan.vehiclePolicy, cashOutVehicleIds = plan.cashOutVehicleIds,
    cashOutGarageIds = plan.cashOutGarageIds, sellParts = plan.sellParts, primarySlot = primary.slot.name,
    cashOut = primary.detail.cashOut, summary = primary.detail.migration}
end

-- Files that belong to no slot (profile-level data) are renamed and passed through.
local function renameProfileFiles(helpers, run, files)
  for name, entry in pairs(files) do
    local isSlot = false
    for _, slot in ipairs(run.sourceSlots) do if name:sub(1, #slot.name + 1) == slot.name .. '/' then isSlot = true end end
    if not isSlot then
      if entry.data then entry.data = helpers.renameData(entry.data, run.profile, run.target, name) end
      run.output[name] = entry
    end
    helpers.checkpoint()
  end
end

-- Public API --------------------------------------------------------------------------------------

-- Each import load owns its progress and scan services.
function M.create(deps)
  local helpers = {checkpoint = deps.progress.checkpoint, supported = deps.scan.supported, legacy = deps.scan.legacy,
    renameData = function(...) return renameData(deps.progress.checkpoint, ...) end}

  -- Apply the selected cash-out policy to every slot before layout migration and report generation.
  return function(profile, target, sourceSlots, files, plan)
    local report = {schemaVersion = names.VERSION, sourceProfile = profile, sourcePath = names.SOURCE_ROOT .. profile,
      targetProfile = target, importedAt = os.time(), slots = {}, policy = 'preserve-as-saved-v2', warnings = {}}
    local run = {profile = profile, target = target, sourceSlots = sourceSlots, report = report, output = {}}
    helpers.checkpoint('preparing', 0.4, 0, true)
    local staged = {}
    for _, slot in ipairs(sourceSlots) do
      assert(helpers.supported(slot), 'Unsupported, incomplete, corrupted or non-RLS slot: ' .. slot.name)
      staged[#staged + 1] = stageSlot(helpers, slot, files, plan)
      if not plan then finishSlot(helpers, run, staged[#staged], #staged) end
    end
    if plan then
      writeLegacyManifests(run, staged, plan)
      for index, item in ipairs(staged) do finishSlot(helpers, run, item, index) end
    end
    renameProfileFiles(helpers, run, files)
    return run.output, report
  end
end

return M
