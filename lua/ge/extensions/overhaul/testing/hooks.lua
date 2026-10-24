-- Optional PR fixture actions. Success always follows an authoritative readback.
-- BeamConnect owns confirmation, session outputs, captures and scenario lifetime.
local M = {}
local saveFinished, saveFailed, generation = 0, 0, 0
local fixtureLocks, partialFixtures = {}, {}
local pendingJobs = 0
local ROOT = 'settings/cloud/overhaul/saves/'

local function module(name)
  return assert(rawget(_G, name), name .. ' unavailable')
end
local function career() return module('overhaul_career_career') end
local function saves() return module('overhaul_career_saveSystem') end
local function inventory() return module('overhaul_career_garage_inventory') end
local function attributes() return module('overhaul_career_economy_playerAttributes') end
local function active() return career().isActive() == true end
local function slot() return saves().getCurrentProfile() end
local function root() return saves().getSaveRootDirectory() or ROOT end
local function finite(n) return type(n) == 'number' and n == n and math.abs(n) <= 1e9 end
local function folder(id)
  assert(type(id) == 'string' and #id <= 64 and id:match('^[A-Za-z0-9][A-Za-z0-9_-]*$'), 'Invalid exact folder ID')
  assert(require('overhaul/lib/save/pathComponent').valid(id), 'Reserved exact folder ID')
  return id
end
local function committed(path)
  local info = path and jsonReadFile(path .. '/info.json')
  return type(info) == 'table' and info.version ~= nil and info.date ~= nil and not info.corrupted
end
local function route()
  local router = rawget(_G, 'ui_router') or (extensions and extensions.ui_router)
  local state = router and router.getCurrent()
  -- Only the resolved UI route is evidence; a navigation request is not.
  return state and state.resolved and state.resolved.name
end

-- Cooperative jobs stop after timeout/cancel and before every further mutation.
local function async(ctx, fn, allowSwitch)
  local epoch, mutationStarted = generation, false
  local startSlot = rawget(_G, 'overhaul_career_saveSystem') and slot()
  local function alive()
    assert(epoch == generation and not ctx.cancelled(), 'Hook cancelled or extension reloaded')
    if startSlot and not allowSwitch then assert(active() and slot() == startSlot, 'Career changed during action') end
  end
  extensions.load('core_jobsystem')
  local function run(job)
    local function wait(label, test, seconds)
      ctx.progress(label)
      local timer = hptimer()
      repeat
        alive()
        if test() then return end
        if timer:stop() >= (seconds or 90) * 1000 then
          error({deadline=label .. ': timed out; read back before retrying'})
        end
        job.sleep(0.1)
      until false
    end
    local function beforeMutation()
      alive()
      mutationStarted = true
    end
    local ok, observed = pcall(fn, wait, beforeMutation, job)
    if not ok and type(observed) == 'table' and observed.refusal then ctx.done(false, observed.refusal)
    elseif ok then ctx.done(true, 'Effect observed', observed)
    elseif mutationStarted or type(observed) == 'table' and observed.deadline then
      local message = type(observed) == 'table' and observed.deadline or tostring(observed)
      if ctx.expire then ctx.expire(message)
      else
        -- Let beamTest expire this original call so its envelope is uncertain.
        -- An internal wait deadline must never turn a pending mutation into a
        -- definite failure. Do no further work while awaiting registry expiry.
        ctx.progress(message)
        while not ctx.cancelled() do job.sleep(0.1) end
      end
    else ctx.done(false, tostring(observed)) end
  end
  pendingJobs = pendingJobs + 1
  local ok, err = pcall(module('core_jobsystem').create, function(job)
    local success, message = xpcall(function() run(job) end, debug.traceback)
    pendingJobs = pendingJobs - 1
    if not success then log('E', 'overhaul_testing_hooks', message) end
  end, 0.01)
  if not ok then pendingJobs = pendingJobs - 1; error(err) end
end

local function save(wait, alive, timeout)
  assert(active(), 'No active Overhaul career')
  local id = slot()
  -- Pending includes deferred autosave requests, not only an in-flight write.
  -- Upgrade that queue now; waiting for it to empty can prevent a fresh slot's
  -- first manual commit forever. saveCurrent merges forced/manual flags even
  -- when another capture is running, and the final empty-queue gate covers it.
  local finished, failed = saveFinished, saveFailed
  local flushed = finished
  alive()
  local store = require('overhaul/lib/save/store').bind(saves())
  assert(store.request('testing:durableSave', nil, {manual=true, force=true}) ~= false, 'Forced save refused')
  wait('Wait for committed info.json and empty save queue', function()
    assert(slot() == id and active(), 'Career changed during save')
    assert(saveFailed == failed, 'Forced save failed')
    -- Ordinary requests may join the queue during capture and then wait for
    -- the autosave interval. Upgrade that follow-up only after a fresh commit
    -- and an idle writer; each completion can trigger at most one flush.
    if saveFinished > flushed and saves().isSavePending() and not saves().isSaveBusy() then
      flushed = saveFinished
      alive()
      assert(store.request('testing:durableSaveFollowup', nil, {manual=true, force=true}) ~= false, 'Follow-up save refused')
    end
    local _, path = slot()
    return saveFinished > finished and not saves().isSavePending() and committed(path)
  end, timeout or 10)
  local _, path = slot()
  return {folderId=id, path=path, committed=true}
end

local function loadEffect(a, reload, wait, alive)
    local id = folder(a.folderId)
    assert(a.tutorial ~= true, 'Overhaul tutorial is disabled; tutorial=true is unsupported')
    local map = a.map
    assert(map == nil or type(map) == 'string' and map:match('^[a-z0-9_]+$'), 'Invalid map')
    wait('boot: wait for game loading', function() return not core_gamestate.loading() end, 120)
    wait('ui: wait for boot acknowledgement', function() return route() ~= nil and not core_gamestate.loading() end, 120)
    local exact = false
    for _, entry in ipairs(FS:directoryList(root(), false, true)) do
      local name = entry:gsub('[/\\]+$', ''):match('([^/\\]+)$')
      assert(not name or name:lower() ~= id:lower() or name == id, 'Folder ID case mismatch: ' .. id)
      if name == id then exact=true end
    end
    local newest = exact and saves().getNewestSave(root() .. id)
    local exists = newest and newest ~= '' and committed(newest)
    if not exists then
      assert(a.createIfMissing and not reload, 'No committed save for exact folder ID: ' .. id)
      -- Empty/half-made directories may be reused; any files are preserved for
      -- inspection rather than being treated as permission to reset a save.
      local files = FS:findFiles(root() .. id, '*', -1, false, false) or {}
      assert(#files == 0, 'Uncommitted slot contains files; left untouched: ' .. id)
      assert(id:match('^[a-z0-9]+$'), 'New folder ID must be lowercase alphanumeric (career naming policy)')
    end
    if reload or not active() or slot() ~= id or map and getCurrentLevelIdentifier() ~= map then
      -- Drain the active career before dispatch. Otherwise the native creator
      -- can accept a queued restart while the old same-slot session still
      -- satisfies every readiness check below. Force deferred autosaves too.
      if active() and saves().isSavePending() then save(wait, alive, 30) end
      alive()
      assert(career().createOrLoadCareerAndStart(id, nil, {
        startingMap=map, startingCash=a.startingCash, tutorial=a.tutorial == true, cheats=false,
      }) ~= false, 'Career load refused: ' .. id)
    end
    wait('career: wait for exact slot and map', function()
      return active() and not career().isStarting() and not core_gamestate.loading()
        and slot() == id and getCurrentLevelIdentifier() ~= nil
        and (map == nil or getCurrentLevelIdentifier() == map)
        and rawget(_G, 'overhaul_career_garage_inventory') ~= nil
        and rawget(_G, 'overhaul_career_economy_playerAttributes') ~= nil
    end, 170)
    local observed = save(wait, alive, 30)
    observed.map = getCurrentLevelIdentifier()
    return observed
end
local function load(a, ctx, reload)
  async(ctx, function(wait, alive) return loadEffect(a, reload, wait, alive) end, true)
end

local function valueMap(values)
  assert(type(values) == 'table' and getmetatable(values) == nil, 'values must be an object')
  local count = 0
  for key, value in pairs(values) do
    count = count + 1
    assert(count <= 16 and type(key) == 'string' and #key <= 64 and key:match('^[%w_-]+$')
      and finite(value), 'Expected at most 16 finite attribute values')
  end
  assert(count > 0, 'values must not be empty')
  assert(#jsonEncode(values) <= 135, 'Split attribute injection into smaller actions so its full preview fits')
end
local function setValues(a, ctx)
  assert(active(), 'No active Overhaul career')
  valueMap(a.values)
  local known = attributes().getAllAttributes()
  for key in pairs(a.values) do assert(known[key] ~= nil, 'Unknown attribute key: ' .. key) end
  if ctx then ctx.overhaulMutation=true end
  attributes().setAttributes(a.values, require('overhaul/lib/finance/metadata').tag(
    {label=a.reason or 'PR test injected attributes', testerForce=true}, 'cheat'))
  local observed = {}
  for key, expected in pairs(a.values) do
    observed[key] = attributes().getAttributeValue(key)
    assert(finite(observed[key]) and math.abs(observed[key] - expected) <= math.max(0.000001, math.abs(expected)*1e-12), 'Attribute readback mismatch: ' .. key)
  end
  return {ok=true, message='Injected attributes observed', observed={values=observed}}
end
local function ownedRecord(id)
  local inv = inventory()
  local record = inv.getVehicles()[id]
  assert(record and record.owned, 'Owned inventory vehicle unavailable')
  return record
end
local function vehicle(id)
  ownedRecord(id)
  local objectId = inventory().getVehicleIdFromInventoryId(id)
  return objectId and getObjectByID(objectId) or nil
end
local function enter(id, wait, alive)
  local record = ownedRecord(id)
  assert(not record.timeToAccess and not record.listedForAuction, 'Vehicle is inaccessible or listed for auction')
  alive()
  local failure
  inventory().enterVehicle(id, nil, function(ok, why) if ok == false then failure = why or 'Vehicle entry refused' end end)
  wait('Wait for player seating readback', function()
    assert(not failure, failure)
    return be:getPlayerVehicleID(0) == inventory().getVehicleIdFromInventoryId(id)
      and gameplay_walk and not gameplay_walk.isWalking()
  end)
end
local function pose(position, rotation)
  assert(type(position) == 'table', 'Position required')
  for i=1,3 do assert(finite(position[i]), 'Invalid position') end
  if rotation then
    local norm = 0
    for i=1,4 do assert(finite(rotation[i]), 'Invalid rotation'); norm=norm+rotation[i]^2 end
    assert(norm > 0, 'Rotation must be nonzero')
  end
end
local function worldRotation(car)
  -- Cluster teleports preserve damage but leave the scene object's rotation
  -- stale. Reconstruct the live body orientation; quatFromDir faces -Y while
  -- the world pose supplied to safeTeleport uses the vehicle's +Y convention.
  return quat(0,0,1,0) * quatFromDir(car:getDirectionVector(), car:getDirectionVectorUp())
end
local function teleport(id, position, rotation, wait, alive)
  pose(position, rotation)
  local car = assert(vehicle(id), 'Vehicle not spawned')
  local pos = vec3(position[1], position[2], position[3])
  local rot = rotation and quat(rotation[1], rotation[2], rotation[3], rotation[4]) or worldRotation(car)
  alive()
  -- safeTeleport applies its own half-turn; cancel that convention so the
  -- requested world orientation (or the existing one) survives unchanged.
  spawn.safeTeleport(car, pos, quat(0,0,1,0) * rot, nil, nil, nil, false, false)
  wait('Wait for position and rotation readback', function()
    if (car:getPosition() - pos):length() >= 2 then return false end
    local now = worldRotation(car)
    local dot = now.x*rot.x + now.y*rot.y + now.z*rot.z + now.w*rot.w
    local norm = math.sqrt((now.x^2+now.y^2+now.z^2+now.w^2)*(rot.x^2+rot.y^2+rot.z^2+rot.w^2))
    return norm > 0 and math.abs(dot / norm) >= 0.995
  end, 10)
  local now = car:getPosition()
  local orientation = worldRotation(car)
  return {inventoryId=id, position={now.x, now.y, now.z}, rotation={orientation.x, orientation.y, orientation.z, orientation.w}}
end

local screens = {home='pause', skills='phone-skills',
  phone='phone-main', events='phone-events', inventory='overhaul.computer.vehicleInventory', computer='overhaul.computer',
  garage='overhaul.computer.vehicleInventory', dealership='overhaul.computer.vehicleShopping',
  map='phone-minimap', insurance='overhaul.computer.insurances', bank='phone-bank', marketplace='phone-marketplace'}
local function open(a, ctx)
  async(ctx, function(wait, alive)
    local target = assert(screens[a.screen], 'Screen not supported')
    assert(a.tab == nil, 'Tabs are manual in phase 1')
    assert(a.facilityId == nil or a.screen == 'computer' or a.screen == 'insurance'
      or a.screen == 'inventory' or a.screen == 'garage', 'facilityId requires a computer screen')
    local facilityId = a.facilityId
    if a.screen == 'inventory' or a.screen == 'garage' then
      assert(route() == screens.computer, 'Open the origin computer menu before inventory')
      local computer = module('overhaul_career_garage_computer')
      facilityId = facilityId or computer.getComputerId()
      assert(facilityId and computer.getComputerId() == facilityId, 'Inventory requires an active origin computer')
      local facility = module('overhaul_world_facilities').getFacility('computer', facilityId)
      assert(facility and facility.id == facilityId, 'Computer facility unavailable')
      alive()
      inventory().openMenuFromComputer(facilityId)
    elseif a.screen == 'dealership' then
      alive()
      module('overhaul_career_market_vehicleShopping').openShop()
    elseif a.screen == 'computer' or a.screen == 'insurance' then
      facilityId = facilityId or module('overhaul_career_garage_computer').getComputerId()
      assert(facilityId, 'Open a valid computer first or supply facilityId')
      local computer = module('overhaul_career_garage_computer')
      local facility = module('overhaul_world_facilities').getFacility('computer', facilityId)
      assert(facility and facility.id == facilityId, 'Computer facility unavailable')
      alive()
      local accepted, navigation = computer.openMenu(facility)
      assert(accepted ~= false and (not navigation or navigation.success ~= false), 'Computer opening refused')
      assert(computer.getComputerId() == facilityId, 'Computer facility readback mismatch')
      if a.screen == 'insurance' then module('overhaul_career_repair_insurance').openMenu(facilityId) end
    elseif target:match('^phone%-') then
      alive()
      -- The UI normally acquires this demand scope after mounting. A route
      -- acknowledgement can precede that acquisition; prepare the same owner
      -- here so an immediate payload check can observe the real projection.
      if a.screen == 'events' then extensions.load('overhaul_phone_apps_freeroamEvents') end
      local result = module('overhaul_phone_phone').openRoute(target)
      assert(not result or result.success ~= false, 'Phone navigation refused')
    else
      local router = rawget(_G, 'ui_router') or extensions.ui_router
      assert(router, 'UI router unavailable')
      alive()
      local result = router.navigate(target)
      assert(not result or result.success ~= false, 'Navigation refused')
    end
    local stable
    wait('Wait for stable resolved UI route', function()
      local resolved = route() == target and (not facilityId
        or module('overhaul_career_garage_computer').getComputerId() == facilityId)
      if not resolved then stable=nil; return false end
      if not facilityId then return true end
      stable = stable or hptimer()
      return stable:stop() >= 500
    end, 15)
    if a.screen == 'events' then
      wait('Wait for Events payload owner', function()
        local owner = rawget(_G, 'overhaul_phone_apps_freeroamEvents')
        return owner and type(owner.buildEventsData) == 'function'
      end, 15)
    end
    return {screen=a.screen, route=route()}
  end)
end

local function checkState(status, message, observed)
  return {status=status, message=message, observed=observed or {}}
end
local function baseline() return {folderId=slot(), money=attributes().getAttributeValue('money')} end
local function sameCareer(before)
  return rawget(_G, 'overhaul_career_career') and rawget(_G, 'overhaul_career_saveSystem')
    and active() and type(before) == 'table' and before.folderId == slot()
end
local function uiData(screen)
  if screen == 'careerCard' then
    local ok, card = pcall(require, 'overhaul/lib/ui/careerCard')
    if not ok or type(card.getData) ~= 'function' then return nil end
    local data = card.getData()
    if not data then return nil end
    -- Sections are keyed for stable selectors, never by presentation order.
    local sections = {}
    for _, section in ipairs(data.sections or {}) do
      local copy = {}
      for key, value in pairs(section) do copy[key]=value end
      if section.rows then copy.rowCount=#section.rows end
      sections[section.id] = copy
    end
    return {sections=sections}
  elseif screen == 'events' then
    local owner = rawget(_G, 'overhaul_phone_apps_freeroamEvents')
    return owner and owner.buildEventsData and owner.buildEventsData()
  end
end
local function field(data, path)
  assert(type(path) == 'string' and #path <= 120 and path:match('^[%w_.-]+$'), 'Invalid UI field path')
  for part in path:gmatch('[^.]+') do
    if type(data) ~= 'table' then return nil end
    data = data[tonumber(part) or part]
  end
  return data
end

-- Fixture implementations live only in dedicated test packages. Normal
-- releases exclude /tests/; absent beamTest never even scans this directory.
local function registerTestFixtures(action)
  local files = {}
  for _, file in ipairs(FS:findFiles('/tests/beamTest/fixtures/', '*.lua', -1, false, false) or {}) do
    if type(file) == 'string' and file:match('^/tests/beamTest/fixtures/[%w_-]+%.lua$') then
      files[#files+1] = file
    end
  end
  table.sort(files)
  for _, file in ipairs(files) do
    local ok, err = pcall(function()
      local fixture = dofile(file)
      assert(type(fixture) == 'table' and type(fixture.register) == 'function', 'Expected register(action)')
      fixture.register(action)
    end)
    if not ok then log('W', 'overhaul_testing_hooks', 'Test fixture ' .. file .. ': ' .. tostring(err)) end
  end
end

local function register()
  local bt = rawget(_G, 'beamTest')
  if not bt or type(bt.apiVersion) ~= 'number' or bt.apiVersion < 1 then return end
  local stamp = jsonReadFile('/gameplay/overhaul/version.json') or {}
  local function registered(result)
    if not result or not result.ok then log('W', 'overhaul_testing_hooks', result and result.message or 'Registration refused') end
    return result and result.ok == true
  end
  local binding = require('overhaul/lib/testing/beamTest')
  local provider = binding.bind(bt, {version=stamp.version_string or stamp.version or 'unknown', compat=1,
    capabilities={}})
  if not registered(provider) then return end
  -- Save observers exist only for a usable optional registry, never normal play.
  M.onOverhaulSaveFinished = function() saveFinished=saveFinished+1 end
  M.onOverhaulSaveFailed = function() saveFailed=saveFailed+1 end
  if extensions and extensions.hookUpdate then
    extensions.hookUpdate('onOverhaulSaveFinished')
    extensions.hookUpdate('onOverhaulSaveFailed')
  end
  local function own(kind, id, spec) return binding.register(provider, kind, id, spec) end
  local str = function(required) return {type='string', required=required, maxLength=120} end
  local id = {type='integer', required=true, min=1}
  local installed = {}
  local function action(name, args, describe, run, careerOnly, timeout)
    local function preview(a)
      local description = describe(a)
      assert(#description <= 200, 'Split fixture arguments so the full injected state fits the preview')
      return description
    end
    local function guarded(a, ctx)
      local ok, result = pcall(run, a, ctx)
      if ok then return result end
      if ctx.overhaulMutation then error(result) end
      return {ok=false, message=tostring(result)}
    end
    installed[name] = registered(own('action', 'overhaul.' .. name, {label=name, args=args, describe=preview,
      run=guarded, careerOnly=careerOnly == true, timeout=timeout or 90}))
    return installed[name]
  end
  action('career.load', {folderId=str(true), map={type='string', default='rls_west_coast'},
    createIfMissing={type='boolean', default=false}, startingCash={type='number', min=0, max=1e9},
    tutorial={type='boolean', default=false}}, function(a)
      return 'Load/reload exact career ' .. a.folderId .. ', map=' .. tostring(a.map or 'rls_west_coast') .. '; create=' .. tostring(a.createIfMissing)
        .. ', new-slot cash=' .. tostring(a.startingCash) .. ', tutorial=false (true unsupported)'
    end, function(a, ctx)
      local args = {}
      for key, value in pairs(a) do args[key]=value end
      args.map = args.map or 'rls_west_coast'
      load(args, ctx, false)
    end, false, 180)
  action('career.save', {timeoutSec={type='number', min=1, max=30, default=10}}, function()
    return 'Force-save current Overhaul career and verify committed info.json; no fixture injection'
  end, function(a, ctx) async(ctx, function(wait, alive) return save(wait, alive, a.timeoutSec) end) end, true, 65)
  action('career.reload', {folderId=str(true)}, function(a)
    return 'Force-save, then reload exact career ' .. a.folderId .. '; no fixture injection'
  end, function(a, ctx)
    assert(active() and slot() == folder(a.folderId), 'Reload must target the active exact slot')
    async(ctx, function(wait, alive)
      save(wait, alive, 10)
      -- Continue through the same cancellation context; never repeat a timed-out save.
      return loadEffect({folderId=a.folderId, map=getCurrentLevelIdentifier()}, true, wait, alive)
    end, true)
  end, true, 180)
  local attributeSupported = action('attributes.set', {values={type='object', required=true}, reason={type='string', maxLength=30}}, function(a)
    valueMap(a.values)
    return 'Inject ' .. jsonEncode(a.values) .. '; reason=' .. tostring(a.reason or 'PR test')
  end, setValues, true)
  action('skill.ensureLevel', {path=str(true), level={type='integer', required=true, min=1, max=100}}, function(a)
    return 'Inject only the XP needed to reach ' .. a.path .. ' level ' .. a.level .. '; preserve higher XP; a level-up popup may appear'
  end, function(a, ctx)
    local skills = module('overhaul_career_progression_skills')
    local branch = skills.getBranchByPath(a.path)
    assert(branch and branch.id ~= 'missing' and branch.attributeKey, 'Unknown skill path')
    local needed = skills.getXPNeededForLevel(a.path, a.level)
    assert(finite(needed) and needed >= 0, 'Unknown skill level')
    local current = attributes().getAttributeValue(branch.attributeKey) or 0
    if current < needed then
      setValues({values={[branch.attributeKey]=needed}, reason='PR test skill prerequisite'}, ctx)
    end
    local level = skills.getBranchLevel(a.path)
    assert(level and level >= a.level, 'Skill level readback mismatch')
    return {ok=true, observed={path=a.path, level=level, xp=attributes().getAttributeValue(branch.attributeKey)}}
  end, true)
  action('vehicle.owned', {tag=str(true), model=str(true), config=str(false), place={type='place'},
    enter={type='boolean', default=false}}, function(a)
    return 'Inject/reuse owned ' .. a.model .. ' (' .. tostring(a.config or 'default') .. '), tag=' .. a.tag
      .. ', place=' .. tostring(a.place or 'here') .. ', enter=' .. tostring(a.enter) .. '; bypass garage capacity'
  end, function(a, ctx)
    async(ctx, function(wait, alive, job)
      assert(active(), 'No active Overhaul career')
      local key = slot() .. ':' .. a.tag
      assert(not fixtureLocks[key], 'Fixture is already being prepared; poll the original call')
      assert(not partialFixtures[key], 'Previous spawn is uncertain; inspect world vehicle ' .. tostring(partialFixtures[key]))
      assert(not ctx.cancelled(), 'Hook cancelled')
      assert(type(a.model) == 'string' and a.model:match('^[A-Za-z0-9_]+$'), 'Invalid vehicle model')
      assert(FS:directoryExists('/vehicles/' .. a.model), 'Vehicle model unavailable')
      if a.config then
        local prefix = 'vehicles/' .. a.model .. '/'
        assert(a.config:sub(1, #prefix) == prefix and a.config:sub(#prefix+1):match('^[A-Za-z0-9_-]+%.pc$'),
          'config must be an exact vehicles/<model>/<name>.pc path')
        assert(FS:fileExists('/' .. a.config), 'Vehicle config unavailable')
      end
      if a.place then
        local p = assert(ctx.places and ctx.places[a.place], 'Place unavailable')
        pose(p.position, p.rotation)
      end
      ctx.onCleanup(function() fixtureLocks[key]=nil end)
      fixtureLocks[key] = true
      local inv, found = inventory(), nil
      for candidate, record in pairs(inv.getVehicles()) do
        if record.beamTestTag == a.tag then assert(not found, 'Duplicate fixture tag'); found = candidate end
      end
      if not found then
        alive()
        local car = core_vehicles.spawnNewVehicle(a.model, {config=a.config, autoEnterVehicle=false})
        -- The engine's explicit false precedes any spawn, unlike a thrown
        -- error or nil after a partially constructed vehicle collection.
        if car == false then error({refusal='Spawn refused; no vehicle created'}) end
        assert(car, 'Spawn outcome unknown; inspect world before retrying')
        partialFixtures[key] = car:getID()
        wait('Wait for spawned vehicle data', function()
          local manager = rawget(_G, 'core_vehicle_manager')
          local data = manager and manager.getVehicleData(car:getID())
          return data and data.vdata ~= nil
        end)
        alive()
        found = assert(inv.addVehicle(car:getID(), nil, {owned=true, starter=true}), 'Ownership refused')
        inv.getVehicles()[found].beamTestTag = a.tag
        partialFixtures[key] = nil
      end
      local record = ownedRecord(found)
      assert(not record.timeToAccess and not record.listedForAuction, 'Tagged fixture is inaccessible or listed for auction')
      assert(record.model == a.model, 'Tagged fixture model mismatch; preserved existing vehicle')
      assert(not a.config or record.config and record.config.partConfigFilename == a.config, 'Tagged fixture config mismatch')
      if not vehicle(found) then
        local failure, restored
        alive()
        inv.spawnVehicle(found, nil, function(ok, why)
          restored = ok ~= false
          if ok == false then failure=why or 'Restore refused' end
        end)
        wait('Wait for restored inventory vehicle', function()
          assert(not failure, failure)
          return restored and vehicle(found) ~= nil
        end)
      end
      alive()
      if not record.partConditions then alive(); inv.updatePartConditions(nil, found) end
      wait('Wait for authoritative ownership and conditions', function() return ownedRecord(found).partConditions ~= nil end)
      if a.place then local p = assert(ctx.places[a.place]); teleport(found, p.position, p.rotation, wait, alive) end
      if a.enter then enter(found, wait, alive) end
      return {inventoryId=found, model=record.model, tag=record.beamTestTag, owned=record.owned}
    end)
  end, true)
  action('vehicle.enter', {inventoryId=id}, function(a)
    return 'Seat player in owned inventory vehicle ' .. a.inventoryId .. '; no ownership injection'
  end, function(a, ctx) async(ctx, function(wait, alive) enter(a.inventoryId, wait, alive); return {inventoryId=a.inventoryId, seated=true} end) end, true)
  action('position.teleport', {inventoryId=id, position={type='vec3', required=true}, rotation={type='quat'}}, function(a)
    return 'Teleport owned vehicle ' .. a.inventoryId .. ' to injected position ' .. jsonEncode(a.position)
      .. ', rotation=' .. jsonEncode(a.rotation)
  end, function(a, ctx) async(ctx, function(wait, alive) return teleport(a.inventoryId, a.position, a.rotation, wait, alive) end) end, true)
  action('ui.open', {screen={type='enum', required=true, enum={'home','skills','phone','events','inventory','computer',
    'garage','dealership','map','insurance','bank','marketplace'}},
    facilityId=str(false), tab=str(false)}, function(a)
    return 'Open ' .. a.screen .. ', facility=' .. tostring(a.facilityId) .. ', tab=' .. tostring(a.tab) .. '; no data injection'
  end, open, false, 20)

  registered(own('check', 'overhaul.money.delta', {label='Observe money delta', careerOnly=true,
    args={expect={type='number', required=true}, tolerance={type='number', min=0, default=0.001}},
    capture=baseline, evaluate=function(a, before)
      if not sameCareer(before) or not finite(before.money) then return checkState('unavailable', 'Capture in the active career first') end
      if core_gamestate.loading() then return checkState('pending', 'Career is loading') end
      local now = attributes().getAttributeValue('money')
      if not finite(now) then return checkState('unavailable', 'Money unavailable') end
      local delta = now - before.money
      return checkState(math.abs(delta-a.expect) <= a.tolerance and 'pass' or 'fail', 'Observed money delta',
        {before=before.money, after=now, delta=delta})
    end}))
  registered(own('check', 'overhaul.inventory.contains', {label='Observe owned inventory', careerOnly=true,
    args={inventoryId={type='integer', min=1}, tag=str(false), model=str(false), count={type='integer', min=0, max=100, default=1}},
    capture=function() return {folderId=slot()} end, evaluate=function(a, before)
      if not sameCareer(before) then return checkState('unavailable', 'Capture in the active career first') end
      if core_gamestate.loading() then return checkState('pending', 'Career is loading') end
      assert(a.inventoryId or a.tag or a.model, 'An inventory selector is required')
      local count = 0
      for candidate, record in pairs(inventory().getVehicles()) do
        if record.owned and (not a.inventoryId or candidate == a.inventoryId)
          and (not a.tag or record.beamTestTag == a.tag) and (not a.model or record.model == a.model) then count=count+1 end
      end
      return checkState(count == a.count and 'pass' or 'fail', 'Observed owned inventory count', {count=count})
    end}))
  local uiSupported = registered(own('check', 'overhaul.ui.values', {label='Observe authoritative UI payload', careerOnly=true,
    args={screen={type='enum', required=true, enum={'careerCard','events'}}, values={type='object', required=true}},
    capture=function() return {folderId=slot()} end, evaluate=function(a, before)
      if not sameCareer(before) then return checkState('unavailable', 'Capture in the active career first') end
      if core_gamestate.loading() then return checkState('pending', 'Career is loading') end
      local data = uiData(a.screen)
      if not data then return checkState('unavailable', 'UI payload owner unavailable in this build') end
      local matches, observed, count = true, {}, 0
      for path, expected in pairs(a.values) do
        count = count + 1
        assert(count <= 16 and (type(expected) == 'string' or type(expected) == 'boolean' or finite(expected)), 'Expected at most 16 scalar UI values')
        local value = field(data, path)
        assert(value == nil or type(value) ~= 'table', 'Select scalar UI fields')
        observed[path] = value == nil and '<missing>' or value
        if value ~= expected then matches=false end
      end
      assert(count > 0, 'values must not be empty')
      return checkState(matches and 'pass' or 'fail', 'Payload only; rendering and input remain manual', observed)
    end}))

  local function callbackContext(cb)
    return {cancelled=function() return false end, progress=function() end,
      expire=function(message) if cb then cb(false, message, {uncertain=true}) end end,
      done=function(ok, message, observed) if cb then cb(ok, message, observed) end end}
  end
  local careerSupported = registered(own('career', 'overhaul', {flavor='overhaul', priority=100,
    detect=function() return rawget(_G, 'overhaul_career_career') ~= nil end,
    isActive=active, currentSlot=slot, saveRoot=root,
    currentDisplayName=function() return saves().getCurrentDisplayName() end,
    reactivate=function()
      local id = assert(slot(), 'No exact slot to reactivate')
      load({folderId=id}, callbackContext(), true)
      return {ok=true, message='Reload requested; await career readiness'}
    end,
    openScreen=function(screen, ctx)
      -- Legacy generic openUi passes no completion context. Never turn a
      -- nested pending envelope into a completed success or orphan navigation.
      if not ctx or type(ctx.done) ~= 'function' then
        return {ok=false, message='Use overhaul.ui.open; legacy openUi has no async completion context'}
      end
      open({screen=screen == 'garage' and 'inventory' or screen}, ctx)
    end,
    isSaving=function() return saves().isSavePending() end,
    isSaveReady=function() local _, path = slot(); return not saves().isSavePending() and committed(path), path end,
    saveFinishedHook=function() return 'onOverhaulSaveFinished' end,
    save=function(cb) async(callbackContext(cb), function(wait, alive) return save(wait, alive, 10) end); return true end,
    loadSlot=function(id, opts, cb)
      opts = opts or {}
      load({folderId=id, map=opts.map or opts.startingMap}, callbackContext(cb), true)
      return true
    end,
    newSlot=function(id, opts, cb)
      opts = opts or {}
      load({folderId=id, map=opts.map or opts.startingMap or 'rls_west_coast', createIfMissing=true,
        startingCash=opts.startingCash, tutorial=opts.tutorial}, callbackContext(cb), false)
      return true
    end,
    getAttribute=function(key) return attributes().getAttributeValue(key) end,
    setAttribute=function(key, value) return setValues({values={[key]=value}}) end,
    addAttribute=function(key, value)
      local current = attributes().getAttributeValue(key)
      assert(current ~= nil, 'Unknown attribute key: ' .. tostring(key))
      assert(finite(current) and finite(value), 'Attribute addition requires finite values')
      return setValues({values={[key]=current+value}})
    end,
  }))
  registered(binding.bind(bt, {version=stamp.version_string or stamp.version or 'unknown', compat=1,
    capabilities={career=careerSupported and installed['career.load'] and installed['career.save'] and installed['career.reload'], attributes=attributeSupported, skills=installed['skill.ensureLevel'], ownedVehicles=installed['vehicle.owned'] and installed['vehicle.enter'], uiValues=uiSupported}}))
  registerTestFixtures(action)
end

-- Registration follows lifecycle events; no idle frame callback or polling.
M.onExtensionLoaded = register
M.onBeamTestReady = register
M.prepareForUnload = function() return pendingJobs == 0 end
-- UI readiness is read from the current resolved router state, including late loads.
M.onExtensionUnloaded = function()
  generation=generation+1
  require('overhaul/lib/testing/beamTest').releaseDetached(rawget(_G, 'beamTest'))
end
return M
