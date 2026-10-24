-- Builds declared proxy levels from installed sources into a cache that only this extension mounts.
-- Config, state, source rules, cache folder, generation, save migration, then the hooks and public API.
local M = {}

-- Config ------------------------------------------------------------------------------------------
local logTag = 'levelProxy'
local catalog = require('overhaul/lib/platform/jsonCatalog')
local levelData = require('overhaul/lib/world/levelData')
require('overhaul/lib/save/store').registerKeys({
  {key = 'world.mapAliases', owner = 'overhaul_world_levelProxy',
    files = {'career/rls_career/levelRenamed.json'}, phase = 'profile', required = true},
})
local RECIPES = '/gameplay/overhaul/world/levelProxies/'
local CACHE = '/temp/rls_career/levelCache/'
local MOUNT = CACHE .. 'mount/'
local PLATE_ROOT = '/vehicles/common/licenseplates/'
local PLATE_FILE = 'licensePlate-default.sktemplate.json'
local PLATE_LEGACY_FILE = 'licensePlate-default.json'
local TEXT = {json = true, prefab = true, lua = true, cs = true, txt = true}
local FORMAT = 6
local SAVE_MARKER = '/career/rls_career/levelRenamed.json'
local SAVE_ROOT = 'settings/cloud/overhaul/saves/'
-- Large binary files stay in the vanilla level and are referenced by absolute path, so they are not copied.
local HEAVY = {dds = true, png = true, jpg = true, jpeg = true, dae = true, cdae = true, ter = true, ogg = true,
  wav = true, bank = true, link = true, spng = true, hdr = true, tif = true, tga = true}

-- State -------------------------------------------------------------------------------------------

local job
local status = {state = 'idle'}
local recipes = {}
local generation = 0
local generatedLevels = {}
local saveMarker = {version = 1, aliases = {}}
local saveMarkerProfile

-- Source files ------------------------------------------------------------------------------------

local function relativePath(value)
  return type(value) == 'string' and value ~= '' and not value:find('[\\%c]')
    and value:sub(1, 1) ~= '/' and not ('/' .. value .. '/'):find('/%.%./')
end

local function validateRecipe(data, file)
  if data.version ~= 1 or not catalog.validId(data.sourceLevel) or not catalog.validId(data.targetLevel)
    or data.sourceLevel == data.targetLevel then return nil, 'requires distinct sourceLevel and targetLevel' end
  if type(data.title) ~= 'string' or data.title == '' or data.title:find('["\\%c]') then return nil, 'invalid title' end
  if data.materialCopiesFile ~= nil and (type(data.materialCopiesFile) ~= 'string'
    or data.materialCopiesFile:sub(1, 1) ~= '/') then return nil, 'materialCopiesFile must be an absolute VFS path' end
  if data.materialCopies ~= nil and (type(data.materialCopies) ~= 'table'
    or type(data.materialCopies.paths) ~= 'table') then return nil, 'materialCopies requires paths' end
  if data.materialCopies and data.materialCopiesFile then return nil, 'choose one material copy source' end
  if data.textPatches ~= nil and type(data.textPatches) ~= 'table' then return nil, 'textPatches must be an array' end
  for _, patch in ipairs(data.textPatches or {}) do
    if type(patch) ~= 'table' or not relativePath(patch.file) or type(patch.replacements) ~= 'table' then
      return nil, 'text patch requires relative file and replacements'
    end
    for _, swap in ipairs(patch.replacements) do
      if type(swap) ~= 'table' or type(swap.from) ~= 'string' or swap.from == '' or type(swap.to) ~= 'string' then
        return nil, 'replacement requires nonempty from and string to'
      end
    end
  end
  if data.legacyCachePaths ~= nil and type(data.legacyCachePaths) ~= 'table' then return nil, 'invalid legacyCachePaths' end
  for _, legacy in ipairs(data.legacyCachePaths or {}) do
    if type(legacy) ~= 'table' or type(legacy.root) ~= 'string' or type(legacy.stamp) ~= 'string'
      or not catalog.validId(legacy.root:match('^/mods/unpacked/([^/]+)/$'))
      or not legacy.stamp:match('^/settings/rls_career/[%w][%w%._%-]*%.json$') then
      return nil, 'unsafe legacy cache path'
    end
  end
  if data.copyDefaultLicensePlate ~= nil and type(data.copyDefaultLicensePlate) ~= 'boolean' then
    return nil, 'copyDefaultLicensePlate must be a boolean'
  end
  data._recipeFile = file
  return data
end

local function loadRecipes()
  local entries = catalog.scan(RECIPES, validateRecipe, logTag)
  local result, targets = {}, {}
  for _, entry in ipairs(entries) do
    if targets[entry.targetLevel] then
      log('W', logTag, 'Ignoring duplicate proxy target: ' .. entry.targetLevel)
    else
      targets[entry.targetLevel] = true
      local recipe = {definition = entry, source = '/levels/' .. entry.sourceLevel .. '/',
        target = '/levels/' .. entry.targetLevel .. '/', output = MOUNT .. 'levels/' .. entry.targetLevel .. '/',
        stampFile = CACHE .. entry.id .. '.json', definitionFile = entry._recipeFile, patches = {}, materialPaths = {}}
      recipe.plateTarget = PLATE_ROOT .. entry.targetLevel .. '/' .. PLATE_FILE
      recipe.plateLegacyTarget = PLATE_ROOT .. entry.targetLevel .. '/' .. PLATE_LEGACY_FILE
      recipe.plateOutput = MOUNT .. recipe.plateTarget:sub(2)
      recipe.plateLegacyOutput = MOUNT .. recipe.plateLegacyTarget:sub(2)
      if entry.copyDefaultLicensePlate ~= false then
        recipe.plateSource = PLATE_ROOT .. entry.sourceLevel .. '/' .. PLATE_FILE
        recipe.plateLegacySource = PLATE_ROOT .. entry.sourceLevel .. '/' .. PLATE_LEGACY_FILE
      end
      entry._recipeFile = nil
      for _, patch in ipairs(entry.textPatches or {}) do recipe.patches[patch.file] = patch.replacements end
      result[#result + 1] = recipe
    end
  end
  for target in pairs(targets) do generatedLevels[target] = true end
  return result
end

local function patch(recipe, rel, data)
  for _, swap in ipairs(recipe.patches[rel] or {}) do
    data = data:gsub(swap.from:gsub('%p', '%%%0'), (swap.to:gsub('%%', '%%%%')))
  end
  return data
end

-- Previews, minimaps and UI images are looked up next to the level's own files, so they are kept.
local function wanted(rel)
  local low = rel:lower()
  local ext = low:match('%.([%w]+)$') or ''
  if low:find('^art/') or low:find('^assets/') then
    return low:find('materials%.json$') ~= nil or low:find('data%.json$') ~= nil or low:find('datablocks%.json$') ~= nil
  end
  if ext == 'jpg' or ext == 'jpeg' or ext == 'png' then return not low:find('heightmap') end
  return not HEAVY[ext]
end

local function checksum(text, step)
  local sum = #text
  for i = 1, #text, step or 97 do sum = (sum * 31 + text:byte(i)) % 4294967291 end
  return sum
end

local function currentStamp(recipe)
  local game = jsonReadFile('integrity.json')
  local mod = jsonReadFile('/gameplay/overhaul/version.json')
  local sourceInfo = readFile(recipe.source .. 'info.json') or ''
  local sourceScene = readFile(recipe.source .. 'main/MissionGroup/items.level.json') or ''
  return {
    format = FORMAT,
    game = type(game) == 'table' and game.version or nil,
    mod = type(mod) == 'table' and mod.version_string or nil,
    source = checksum(sourceInfo) .. ':' .. checksum(sourceScene),
    materials = checksum(recipe.definition.materialCopiesFile and readFile(recipe.definition.materialCopiesFile) or '', 1),
    recipe = checksum(readFile(recipe.definitionFile) or '', 1),
  }
end

local function stampMatches(saved, current)
  return type(saved) == 'table' and saved.format == current.format and saved.game == current.game
    and saved.mod == current.mod and saved.source == current.source and saved.provided == current.provided
    and saved.materials == current.materials and saved.recipe == current.recipe
end

-- An unpacked RLS mod's own level files, so a map edit that adds or removes one shows up; a zipped
-- release changes its version instead.
local function unpackedLevelFiles(recipe)
  local real = (FS:getFileRealPath('/lua/ge/extensions/overhaul/world/levelProxy.lua') or ''):gsub('\\', '/')
  local name = real:match('/mods/unpacked/([^/]+)/lua/ge/extensions/overhaul/world/levelProxy%.lua$')
  if not name then return nil end
  local root = '/mods/unpacked/' .. name .. recipe.target
  local list = {}
  for _, file in ipairs(FS:findFiles(root, '*', -1, true, false) or {}) do list[#list + 1] = file:sub(#root + 1):lower() end
  table.sort(list)
  return list
end

-- Files the RLS mod ships under the target level are never generated, so its versions win.
local function providedByMod(recipe, unpacked)
  local generated = {}
  for _, file in ipairs(FS:findFiles(recipe.output, '*', -1, true, false) or {}) do generated[file:sub(#recipe.output + 1):lower()] = true end
  local provided = {}
  for _, file in ipairs(FS:findFiles(recipe.target, '*', -1, true, false) or {}) do
    local rel = file:sub(#recipe.target + 1):lower()
    if not generated[rel] then provided[rel] = true end
  end
  for _, rel in ipairs(unpacked or {}) do provided[rel] = true end
  return provided
end

-- Generated references to files the mod provides point at the mod's copy, not vanilla.
local function redirectMaterialPath(recipe, path)
  local canonical = '/' .. path:gsub('\\', '/'):gsub('^/', ''):lower():gsub('%.cdae$', '.dae')
  local target = recipe.materialPaths[canonical]
  if not target then return end
  local bare = path:gsub('\\', '/'):gsub('^/', ''):gsub('%.[cC][dD][aA][eE]$', '.dae')
  if target:lower():sub(-#canonical) == canonical then target = target:sub(1, #target - #bare) .. bare end
  return path:sub(1, 1) == '/' and target or target:gsub('^/', '')
end

local function redirect(recipe, text, provided)
  text = text:gsub("(/?)" .. recipe.source:sub(2):gsub("%p", "%%%0") .. "([^\"'%c]+)", function(slash, rel)
    if provided[rel:lower()] then return slash .. recipe.target:sub(2) .. rel end
  end)
  text = text:gsub('"([^"%c]+)"', function(path)
    local target = redirectMaterialPath(recipe, path)
    return target and '"' .. target .. '"'
  end)
  return (text:gsub("'([^'%c]+)'", function(path)
    local target = redirectMaterialPath(recipe, path)
    return target and "'" .. target .. "'"
  end))
end

-- Cache folder ------------------------------------------------------------------------------------

local function removeFiles(files)
  for _, file in ipairs(files) do FS:removeFile(file) end
end

local function removeGeneratedLevel(recipe)
  local files = FS:findFiles(recipe.output, '*', -1, true, false) or {}
  files[#files + 1] = recipe.stampFile
  removeFiles(files)
end

local function removeTree(root, files)
  removeFiles(files)
  local dirs = FS:findFiles(root, '*', -1, false, true) or {}
  table.sort(dirs, function(a, b) return #a > #b end)
  for _, dir in ipairs(dirs) do FS:directoryRemove(dir) end
  FS:directoryRemove(root)
end

-- The unpacked mod earlier versions generated goes once, but only the files its stamp lists; a folder
-- holding anything else stays.
local function removeLegacy(recipe, legacy)
  local stamp = jsonReadFile(legacy.stamp)
  if type(stamp) ~= 'table' or not catalog.finite(stamp.format) or type(stamp.files) ~= 'table' then
    if FS:directoryExists(legacy.root) or FS:fileExists(legacy.stamp) then
      log('W', logTag, 'Left ' .. legacy.root .. ' in place: no record that RLS generated it')
    end
    return
  end
  if not FS:directoryExists(legacy.root) then
    if FS:fileExists(legacy.stamp) then FS:removeFile(legacy.stamp) end
    return
  end
  local level = legacy.root .. recipe.target:sub(2)
  local generated = {}
  for _, rel in ipairs(stamp.files) do
    if relativePath(rel) then generated[(level .. rel):lower()] = true end
  end
  local files = FS:findFiles(legacy.root, '*', -1, true, false) or {}
  for _, file in ipairs(files) do
    if not generated[file:lower()] then
      log('W', logTag, 'Left ' .. legacy.root .. ' in place: it holds files RLS did not generate')
      return
    end
  end
  if FS:isMounted(legacy.root) then FS:unmount(legacy.root) end
  removeTree(legacy.root, files)
  FS:removeFile(legacy.stamp)
  log('I', logTag, 'Removed the proxy that earlier versions generated in ' .. legacy.root)
end

local function mountGenerated(recipe)
  if not FS:isMounted(MOUNT) and not FS:mountList({{srcPath = MOUNT}}) then
    log('E', logTag, 'Could not mount ' .. MOUNT)
    return false
  end
  -- The level list is cached; tell it the level appeared so it shows with its title.
  core_levels.onFilesChanged({{filename = recipe.target .. 'info.json', type = 'added'}})
  extensions.hook('onOverhaulMapCatalogChanged')
  return true
end

-- Generation --------------------------------------------------------------------------------------

local function failWith(message)
  status = {state = 'error', error = message}
  log('E', logTag, message)
  return false
end

-- The recipe lists the material copies; every path must exist before a build starts.
local function loadMaterialRecipe(recipe)
  local data = recipe.definition.materialCopies or {paths = {}}
  if recipe.definition.materialCopiesFile then data = jsonReadFile(recipe.definition.materialCopiesFile) end
  if type(data) ~= 'table' or type(data.paths) ~= 'table' then return failWith('Missing material copy paths') end
  recipe.materialPaths = data.paths
  for source, path in pairs(recipe.materialPaths) do
    if type(source) ~= 'string' or type(path) ~= 'string' or not FS:fileExists(path) then
      return failWith('Missing material copy: ' .. tostring(path))
    end
  end
  return true
end

local function finish(recipe, stamp, files)
  stamp.files = files
  jsonWriteFile(recipe.stampFile, stamp, true)
  status = {state = 'ready', files = #files}
  log('I', logTag, string.format('Generated %s from %s: %d files', recipe.target, recipe.source, #files))
end

-- Copies every wanted vanilla file into the cache, yielding between files so the game keeps running.
local function copySourceFiles(recipe, jobHandle, provided, token)
  local files, budget = {}, os.clockhp()
  for _, file in ipairs(FS:findFiles(recipe.source, '*', -1, true, false) or {}) do
    if token ~= generation then return nil end
    local rel = file:sub(#recipe.source + 1)
    if wanted(rel) and not provided[rel:lower()] then
      local data = readFile(file)
      if data then
        if TEXT[(rel:match('%.([%w]+)$') or ''):lower()] then data = patch(recipe, rel, redirect(recipe, data, provided)) end
        if rel == 'info.json' then data = data:gsub('"title"%s*:%s*"[^"]*"', function() return '"title": "' .. recipe.definition.title .. '"' end, 1) end
        writeFile(recipe.output .. rel, data)
        files[#files + 1] = rel
      end
    end
    if os.clockhp() - budget > 0.008 then jobHandle.sleep(0); budget = os.clockhp() end
  end
  return files
end

-- Plate lookup uses the active level name, so proxy maps need their own template path.
-- Keep source asset references unchanged; a separately supplied proxy design takes precedence.
local function copyDefaultLicensePlate(recipe)
  if not recipe.plateSource then return end
  if FS:fileExists(recipe.plateTarget) and not recipe.retainedPlateOutputs[recipe.plateOutput] then return end
  if FS:fileExists(recipe.plateLegacyTarget) and not recipe.retainedPlateOutputs[recipe.plateLegacyOutput] then return end
  -- Stock merges missing native format keys from the sibling legacy design.
  local foundSource = false
  for _, plate in ipairs({
    {source = recipe.plateSource, output = recipe.plateOutput},
    {source = recipe.plateLegacySource, output = recipe.plateLegacyOutput},
  }) do
    local template = readFile(plate.source)
    if template then
      foundSource = true
      if not FS:fileExists(plate.output) and not writeFile(plate.output, template) then
        log('W', logTag, 'Could not write proxy license plate; using the game fallback: ' .. plate.output)
      end
    end
  end
  if not foundSource and recipe.definition.copyDefaultLicensePlate == true then
    log('W', logTag, 'Missing source license plate; using the game fallback: ' .. recipe.plateSource)
  end
end

-- Preparation alone refreshes plates; rebuilding the map must preserve any retained template.
-- A retained cache file must never be mistaken for another mod's design.
local function removeGeneratedPlates(recipe)
  recipe.retainedPlateOutputs = {}
  for _, output in ipairs({recipe.plateOutput, recipe.plateLegacyOutput}) do
    FS:removeFile(output)
    if FS:fileExists(output) then
      recipe.retainedPlateOutputs[output] = true
      log('W', logTag, 'Could not remove generated license plate; retaining the old template and retrying next preparation: ' .. output)
    end
  end
end

-- Keeps the generated level when its stamp still matches the sources; returns true when it did.
local function reuseGeneratedLevel(recipe, stamp, saved)
  if not (stampMatches(saved, stamp) and FS:fileExists(recipe.output .. 'info.json')) then return false end
  copyDefaultLicensePlate(recipe)
  if not mountGenerated(recipe) then return failWith("Could not mount proxy cache") end
  status = {state = 'ready', files = #(saved.files or {})}
  return true
end

local function generate()
  if job then return end
  recipes = loadRecipes()
  local pending, failed = {}, false
  for _, recipe in ipairs(recipes) do
    -- Reveal separately mounted designs before deciding whether to supply the default.
    -- Only these tiny templates are refreshed on reuse; the generated map remains cached.
    removeGeneratedPlates(recipe)
    for _, legacy in ipairs(recipe.definition.legacyCachePaths or {}) do removeLegacy(recipe, legacy) end
    if not FS:fileExists(recipe.source .. 'info.json') then
      failWith('Missing source level: ' .. recipe.definition.sourceLevel)
      failed = true
    elseif not loadMaterialRecipe(recipe) then
      failed = true
    else
      local stamp = currentStamp(recipe)
      local unpacked = unpackedLevelFiles(recipe)
      stamp.provided = unpacked and checksum(table.concat(unpacked, '\n')) or nil
      if not reuseGeneratedLevel(recipe, stamp, jsonReadFile(recipe.stampFile)) then
        pending[#pending + 1] = {recipe = recipe, stamp = stamp, provided = providedByMod(recipe, unpacked)}
      end
    end
  end
  if #pending == 0 then
    if failed then failWith('One or more proxy levels could not be prepared') end
    return
  end
  local token = generation
  status = {state = 'generating'}
  job = core_jobsystem.create(function(jobHandle)
    for _, build in ipairs(pending) do
      if token ~= generation then return end
      local recipe = build.recipe
      removeGeneratedLevel(recipe)
      guihooks.trigger('toastrMsg', {type = 'info', title = 'Preparing ' .. recipe.definition.title,
        msg = 'Building the map from your installed source level.', config = {timeOut = 6000}})
      local files = copySourceFiles(recipe, jobHandle, build.provided, token)
      if not files or token ~= generation then return end
      copyDefaultLicensePlate(recipe)
      if mountGenerated(recipe) then
        finish(recipe, build.stamp, files)
      else
        failed = true
      end
    end
    job = nil
    if failed then failWith('One or more proxy levels could not be prepared') end
  end)
end

-- Save migration ----------------------------------------------------------------------------------

local function saveSlot(savePath)
  if type(savePath) ~= 'string' then return nil end
  local normalized = savePath:gsub('\\', '/'):gsub('^/', '')
  local slot = normalized:sub(#SAVE_ROOT + 1):match('^([^/]+/[^/]+)/?$')
  if normalized:sub(1, #SAVE_ROOT) ~= SAVE_ROOT or not slot
    or normalized:find('[%c:]') or ('/' .. normalized .. '/'):find('/%.%./')
    or ('/' .. normalized .. '/'):find('/%./') then return nil end
  return SAVE_ROOT .. slot
end

local function equalSaveData(left, right)
  if type(left) ~= type(right) then return false end
  if type(left) ~= 'table' then return left == right end
  for key, value in pairs(left) do if not equalSaveData(value, right[key]) then return false end end
  for key in pairs(right) do if left[key] == nil then return false end end
  return true
end

-- Only migration-owned temporaries are renamed; the source map filename and its bytes stay untouched.
local function replaceSaveJson(target, data)
  local temporary = target .. '.alias.tmp'
  local written = jsonWriteFile(temporary, data, true)
  -- Stock jsonWriteFile does not check f:write/f:close; verify the complete temporary before replacing live data.
  local bytes = written and readFile(temporary)
  local expected = written and jsonEncodePretty(data, 1)
  if type(bytes) ~= 'string' or type(expected) ~= 'string'
    or bytes:gsub('\r\n', '\n') ~= expected:gsub('\r\n', '\n') then
    log('E', logTag, 'Could not verify migrated save temporary: ' .. temporary .. '; original retained')
    return false
  end
  -- The engine returns 0 on success, including replacement of an existing target.
  if FS:renameFile(temporary, target) ~= 0 then
    log('E', logTag, 'Could not migrate save file: ' .. target .. '; retry on the next load')
    return false
  end
  return true
end

local function currentMapCopy(file, target, scope, aliases)
  for _, alias in ipairs(aliases) do
    if catalog.validId(scope.levelId) and scope.levelId ~= alias.from
      and levelData.renameMapFile(file, scope, {alias}) == target then return true end
  end
  return false
end

-- Matching destinations coalesce; current-map history takes precedence over its retained legacy copy.
local function stageSaveAliases(savePath, scope, aliases)
  local output, root = {}, savePath .. '/career/'
  for _, discovered in ipairs(FS:findFiles(root, '*.json', -1, true, false) or {}) do
    local file = discovered:gsub('\\', '/'):gsub('^/', '')
    assert(file:sub(1, #root) == root and not ('/' .. file .. '/'):find('/%.%./'), 'Unsafe save record: ' .. file)
    if file ~= savePath .. SAVE_MARKER and not file:find('/vehicles/damage/', 1, true) then
      local data = jsonReadFile(file)
      assert(type(data) == 'table', 'Unreadable save record: ' .. file)
      local renamed, changed = levelData.renameMapData(data, scope, aliases)
      local target = levelData.renameMapFile(file, scope, aliases)
      if target ~= file and FS:fileExists(target) then
        local existing = jsonReadFile(target)
        assert(type(existing) == 'table', 'Unreadable save destination: ' .. target)
        local destination = levelData.renameMapData(existing, scope, aliases)
        if not equalSaveData(destination, renamed) then
          assert(currentMapCopy(file, target, scope, aliases), 'Save filename collision: ' .. target)
          log('W', logTag, 'Retained aliased-map history at ' .. target .. '; original history kept at ' .. file)
          renamed = destination
        end
        changed = not equalSaveData(existing, renamed)
      else
        changed = changed or target ~= file
      end
      local prior = output[target]
      assert(not prior or equalSaveData(prior.data, renamed), 'Save filename collision: ' .. target)
      output[target] = {data = renamed, changed = changed or (prior and prior.changed) or false}
    end
  end
  return output
end

local function pendingSaveAliases(scope, marker)
  local result, scopes, fresh, found = {}, {}, {}, {}
  for _, alias in ipairs(levelData.mapAliases(scope)) do
    fresh[levelData.mapAliasKey(alias)] = true
  end
  for _, alias in ipairs(levelData.loadAliases('map')) do
    local key = levelData.mapAliasKey(alias)
    local originalScope = marker.pending and marker.pending[key]
    local qualified = fresh[key]
    if originalScope then
      assert(type(originalScope) == 'table', 'Invalid pending map alias scope: ' .. key)
      for _, candidate in ipairs(levelData.mapAliases(originalScope)) do
        if levelData.mapAliasKey(candidate) == key then
          qualified, found[key] = true, true
          break
        end
      end
    end
    if qualified and not marker.aliases[key] and not scopes[key] then
      result[#result + 1], scopes[key] = alias, originalScope or scope
    end
  end
  for key in pairs(marker.pending or {}) do
    assert(found[key], 'Pending map alias data is unavailable: ' .. tostring(key))
  end
  return result, scopes
end

-- Completion belongs to the profile and is saved with every rotated slot, without changing saveSystemVersion.
local function readSaveMarker(savePath)
  local marker = jsonReadFile(savePath .. SAVE_MARKER)
  if type(marker) ~= 'table' then marker = {} end
  return {version = 1, aliases = type(marker.aliases) == 'table' and marker.aliases or {},
    pending = type(marker.pending) == 'table' and marker.pending or nil}
end

local function migrateSaveLevel(savePath)
  saveMarker = {version = 1, aliases = {}}
  saveMarkerProfile = nil
  savePath = saveSlot(savePath)
  if not savePath or not FS:directoryExists(savePath .. '/career') then return end
  saveMarkerProfile = savePath:match('^(.*)/[^/]+$')
  local info = jsonReadFile(savePath .. '/info.json') or {}
  local general = jsonReadFile(savePath .. '/career/general.json') or {}
  if type(info) ~= 'table' then info = {} end
  if type(general) ~= 'table' then general = {} end
  local scope = {saveVersion = tonumber(info.version), levelId = general.level}
  saveMarker = readSaveMarker(savePath)
  local selected, aliases, scopes = pcall(pendingSaveAliases, scope, saveMarker)
  if not selected then log('E', logTag, 'Could not resume map migration: ' .. tostring(aliases)); return false end
  if #aliases == 0 then return true end
  local ok, staged = pcall(stageSaveAliases, savePath, scope, aliases)
  if not ok then log('E', logTag, 'Left map migration unchanged: ' .. tostring(staged)); return false end
  -- Keep each alias's original scope before general.json or an autosave can change its level/version evidence.
  local progress = {version = 1, aliases = deepcopy(saveMarker.aliases), pending = deepcopy(scopes)}
  if not replaceSaveJson(savePath .. SAVE_MARKER, progress) then return false end
  saveMarker = progress
  local renamed, paths = 0, {}
  for path in pairs(staged) do paths[#paths + 1] = path end
  table.sort(paths)
  for _, target in ipairs(paths) do
    local entry = staged[target]
    if entry.changed then
      if not replaceSaveJson(target, entry.data) then return false end
      renamed = renamed + 1
    end
  end
  local completed = {version = 1, aliases = deepcopy(saveMarker.aliases), files = renamed}
  for _, alias in ipairs(aliases) do completed.aliases[levelData.mapAliasKey(alias)] = true end
  if not replaceSaveJson(savePath .. SAVE_MARKER, completed) then return false end
  saveMarker = completed
  if renamed > 0 then log('I', logTag, string.format('Migrated map aliases in %s (%d files)', savePath, renamed)) end
  return true
end

-- Public API --------------------------------------------------------------------------------------

M.migrateSaveLevel = migrateSaveLevel
M.getStatus = function() return status end
M.getGeneratedLevels = function()
  if #recipes == 0 then recipes = loadRecipes() end
  local result = {}
  for level in pairs(generatedLevels) do result[level] = true end
  return result
end
M.regenerate = function()
  generation = generation + 1
  job = nil
  for _, recipe in ipairs(recipes) do removeGeneratedLevel(recipe) end
  generate()
end
-- Called after leaving generated levels; captured recipes survive the mod being unmounted.
M.removeGenerated = function()
  generation = generation + 1
  job = nil
  if #recipes == 0 then recipes = loadRecipes() end
  if FS:isMounted(MOUNT) then FS:unmount(MOUNT) end
  for _, recipe in ipairs(recipes) do
    removeGeneratedLevel(recipe)
    for _, legacy in ipairs(recipe.definition.legacyCachePaths or {}) do removeLegacy(recipe, legacy) end
  end
  for level in pairs(generatedLevels) do
    core_levels.onFilesChanged({{filename = '/levels/' .. level .. '/info.json', type = 'deleted'}})
  end
  removeTree(CACHE, FS:findFiles(CACHE, '*', -1, true, false) or {})
  status = {state = 'idle'}
end

-- Game hooks --------------------------------------------------------------------------------------

M.onOverhaulSetProfile = migrateSaveLevel
function M.onOverhaulSaveCurrentProfile(savePath, _, writer)
  savePath = saveSlot(savePath)
  if not savePath then return end
  local profile = savePath:match('^(.*)/[^/]+$')
  if saveMarkerProfile ~= profile then
    -- An owner-only reload may receive no profile-selection hook; restore its persisted marker before rotating.
    local _, currentPath = overhaul_career_saveSystem.getCurrentProfile()
    currentPath = saveSlot(currentPath)
    if not currentPath or currentPath:match('^(.*)/[^/]+$') ~= profile then currentPath = savePath end
    saveMarker, saveMarkerProfile = readSaveMarker(currentPath), profile
  end
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  return writer.json(savePath .. SAVE_MARKER, deepcopy(saveMarker), true)
end
M.onExtensionLoaded = generate

return M
