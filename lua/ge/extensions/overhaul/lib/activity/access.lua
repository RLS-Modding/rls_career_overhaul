-- Activity host access: get() is the production entry, and career.lua publishes the same object as career.activity.
-- Map: career lifetime, owner adoption, policy indexing, instance APIs and the shared access object.
local hostLib = require('overhaul/lib/activity/host')
local catalogLib = require('overhaul/lib/activity/catalog')
local definitionLib = require('overhaul/lib/activity/definition')
local optional = require('overhaul/lib/platform/optional')

local M = {}

-- Config --------------------------------------------------------------------------------------------

-- Deprecated aliases call lexical engine functions, bypassing the wrapped modern exports.
local mutations = {"load", "reload", "refresh", "unload", "unloadExcept", "loadAtRoot",
  "loadModulesInDirectory", "deserialize", "loadModule", "unloadModule", "reloadModule", "use",
  "getSerializationData"}

-- State ---------------------------------------------------------------------------------------------

local shared = nil
local engine, revision = nil, 0

-- Helpers -------------------------------------------------------------------------------------------


local function packResults(...)
  return {n = select("#", ...), ...}
end

-- Bumps the revision before and after the call, and re-raises whatever the call raised.
local function wrap(original)
  return function(...)
    -- Both boundaries matter when an owner queries policies from its load/unload hook.
    revision = revision + 1
    local results = packResults(pcall(original, ...))
    revision = revision + 1
    if not results[1] then error(results[2], 0) end
    return unpack(results, 2, results.n)
  end
end

-- Existing proxies also signal owner replacements and newly loaded dependencies through this method.
local function wrapProxyPublication()
  -- The proxy class is private to the constructor, so it is found through the constructor's upvalues.
  local constructor = newExtensionProxy
  local position = 1
  while true do
    local name, value = debug.getupvalue(constructor, position)
    if not name then break end
    if name == "ExtensionProxy" and type(value) == "table" then
      local original = rawget(value, "_updateHooks")
      if type(original) == "function" then value._updateHooks = wrap(original) end
      break
    end
    position = position + 1
  end
end

local function attach(current)
  engine, revision = current, revision + 1
  if type(current) ~= "table" then return end
  for _, name in ipairs(mutations) do
    local original = rawget(current, name)
    if type(original) == "function" then current[name] = wrap(original) end
  end
  wrapProxyPublication()
end

-- The revision, first attaching to the engine table again when it has been replaced.
local function currentRevision()
  local current = extensions
  if current ~= engine then attach(current) end
  return revision
end

-- Career epochs invalidate retained hosts even when no owner hook runs.
local function careerLifetime()
  local token, serial, lifecycleHost, owner = nil, 0, nil, nil
  local scopes = {'career'}
  return function()
    if not lifecycleHost then lifecycleHost = require('overhaul/lib/lifecycle/host') end
    -- A lifetime token observes the career boundary without copying the epochs on every query.
    if not token or not lifecycleHost.isCurrent(token) then
      token = lifecycleHost.track('activity', scopes)
      serial = serial + 1
    end
    local career = rawget(_G, 'overhaul_career_career')
    if owner ~= career then owner, serial = career, serial + 1 end
    return serial
  end
end

-- The definition an owner offers for `id`: its `activity` field, or one table keyed by owner id.
local function offeredDefinition(offer, id)
  if type(offer) ~= 'table' then return nil end
  local definition = offer
  if type(offer.id) ~= 'string' then definition = offer[id] end
  if type(definition) ~= 'table' or definition.id ~= id then return nil end
  return definition
end

-- Access instances ----------------------------------------------------------------------------------

-- Each access instance keeps its own rejection cache and policy index.
local function newState(opts)
  local state = {
    opts = opts,
    epochOf = opts.epoch or careerLifetime(),
    revisionOf = opts.revision or currentRevision,
    host = nil,                  -- the activity host of the current career epoch
    sessionEpoch = nil,          -- the career epoch that host belongs to
    adopted = {},                -- activity id -> the definition registered from its owner
    owners = opts.catalog,       -- catalog index; read from disk once unless injected
    publishedDefinitions = {},   -- activity id -> the definition its owner last offered
    publishedOwners = {},        -- activity id -> the owner extension that offered it
    rejected = {},               -- activity id -> the offered definition the host refused, not retried
    indexDirty = true,           -- the policy index must be rebuilt before the next policy query
    adoptionRevision = nil,      -- the engine revision the adoptions were made against
    built = {},                  -- extension -> module -> {extension, value}: factory results
    reported = setmetatable({}, {__mode = 'k'}),  -- definitions already reported as refused
    empty = {},
    blockResults = {},           -- per block kind: the borrowed buffer that blocking() returns
    blockIndex = {}, observationIndex = {}, routeIndex = {}, movingIndex = {}, tutorialIndex = {},
  }
  for kind in pairs(definitionLib.BLOCK_KINDS) do state.blockResults[kind] = {} end
  return state
end

-- Catalog and definitions ---------------------------------------------------------------------------

local function ownerCatalog(state)
  if not state.owners then state.owners = catalogLib.load() end
  return state.owners
end

-- Cache one factory result per live extension so reloads replace definitions and closures.
local function builtDefinition(state, ownerExtension, entry)
  local modules = state.built[entry.extension]
  if not modules then modules = {} state.built[entry.extension] = modules end
  local cached = modules[entry.definition]
  if cached and cached.extension == ownerExtension then return cached.value end
  local ok, value = pcall(require, entry.definition)
  local problem = not ok and tostring(value) or nil
  if ok and type(value) ~= 'function' then
    problem = 'the module must return a function of the owner extension (a factory), not a ' .. type(value)
  elseif ok then
    ok, value = pcall(value, ownerExtension)
    if not ok then problem = tostring(value)
    elseif type(value) ~= 'table' then problem = 'the factory returned no definition' end
  end
  if problem then
    log('E', 'activity', 'Could not build the activity definition of ' .. entry.id .. ' from ' .. entry.definition .. ': ' .. problem)
    value = nil
  end
  modules[entry.definition] = {extension = ownerExtension, value = value}
  return value
end

-- Unloaded owners contribute nothing; lookup must never load an extension.
local function definitionOf(state, entry)
  local ownerExtension = optional(entry.extension)
  if type(ownerExtension) ~= 'table' then return nil end
  local offer = ownerExtension.activity
  if offer == nil and entry.definition then offer = builtDefinition(state, ownerExtension, entry) end
  return offeredDefinition(offer, entry.id), ownerExtension
end

-- Host and adoption ---------------------------------------------------------------------------------

-- The activity host for the current career epoch. A new epoch drops every adoption.
local function currentHost(state)
  local epoch = state.epochOf()
  if state.host and epoch ~= state.sessionEpoch then
    state.host, state.adopted, state.publishedDefinitions, state.publishedOwners = nil, {}, {}, {}
    state.rejected, state.indexDirty, state.adoptionRevision = {}, true, nil
    state.built = {}
    -- A shared access owner must discover newly mounted manifests when career core reloads.
    if not state.opts.catalog then state.owners = nil end
  end
  if not state.host then state.host, state.sessionEpoch = hostLib.new(), epoch end
  return state.host
end

-- Logs a refused definition once per definition table.
local function reportRefused(state, id, definition, errors)
  if state.reported[definition] then return end
  state.reported[definition] = true
  log('E', 'activity', 'Could not adopt the activity definition of ' .. id .. ': ' .. table.concat(errors or {}, '; '))
end

-- Remove adopted children first; observer parents are metadata only.
local function drop(state, host, id)
  for _, child in ipairs(host.children(id)) do
    if state.adopted[child] and host.unregister(child) then state.adopted[child], state.indexDirty = nil, true end
  end
  if host.unregister(id) then state.adopted[id], state.indexDirty = nil, true end
end

-- Children wait for an adopted parent and follow its replacement lifetime.
local function adopt(state, id, depth)
  local host = currentHost(state)
  if type(id) ~= 'string' then return host end
  local entry = ownerCatalog(state).byId[id]
  if not entry then return host end
  local definition, ownerExtension = definitionOf(state, entry)
  if state.publishedDefinitions[id] ~= definition or state.publishedOwners[id] ~= ownerExtension then
    state.publishedDefinitions[id], state.publishedOwners[id], state.rejected[id], state.indexDirty = definition, ownerExtension, nil, true
  end
  if definition and state.rejected[id] == definition then return host end
  if definition and definition.parent and definition.role == 'child' then
    if (depth or 0) < 8 then adopt(state, definition.parent, (depth or 0) + 1) end
    if not host.has(definition.parent) then definition = nil end
  end
  local old = state.adopted[id]
  if definition == old then return host end
  if old and definition then
    if host.replace(definition) then
      state.adopted[id], state.indexDirty = definition, true
      return host
    end
    -- The new load's definition cannot take the old one's place: never keep routing to the old load.
    drop(state, host, id)
    old = state.adopted[id]
  end
  if old then
    drop(state, host, id)
  elseif definition and not host.has(id) then
    local ok, errors = host.register(definition)
    if ok then
      state.adopted[id], state.indexDirty = definition, true
    else
      state.rejected[id] = definition
      reportRefused(state, id, definition, errors)
    end
  end
  return host
end

local function adoptAll(state)
  for _, entry in ipairs(ownerCatalog(state).list) do adopt(state, entry.id) end
  return currentHost(state)
end

-- Policy index --------------------------------------------------------------------------------------

local function isBlocking(definition, kind)
  if definition.blockingProbe then return definition.blockingProbe(kind) == true end
  return definition.probe ~= nil and definition.probe() == true
end

local function anyRunning(index)
  for _, definition in ipairs(index) do
    if definition.probe and definition.probe() then return true end
  end
  return false
end

local function resetPolicyIndex(state)
  state.blockIndex, state.observationIndex = {}, {}
  state.routeIndex, state.movingIndex, state.tutorialIndex = {}, {}, {}
  for kind in pairs(definitionLib.BLOCK_KINDS) do state.blockIndex[kind], state.observationIndex[kind] = {}, {} end
end

-- Catalog position preserves short-circuit order across policy readers.
local function includePolicyDefinition(state, indexing, definition)
  if not definition then return end
  indexing.seen[definition.id] = true
  indexing.count = indexing.count + 1
  indexing.catalogPosition[definition.id] = indexing.count
  for _, kind in ipairs(definition.blocks or state.empty) do
    local blockList = state.blockIndex[kind]
    blockList[#blockList + 1] = definition
    local observations = state.observationIndex[kind]
    observations[#observations + 1] = definition
  end
  if definition.phoneRoute then state.routeIndex[#state.routeIndex + 1] = definition end
  if definition.allowPhoneWhileMoving then state.movingIndex[#state.movingIndex + 1] = definition end
  if definition.blocksTutorialPhone then state.tutorialIndex[#state.tutorialIndex + 1] = definition end
end

-- A loaded child may supply policy before its parent is adopted.
local function policyDefinitionFor(state, host, entry)
  local definition = host.get(entry.id)
  local publishedDefinition = state.publishedDefinitions[entry.id]
  if not definition and publishedDefinition and state.rejected[entry.id] ~= publishedDefinition
      and publishedDefinition.role == 'child' then
    if definitionLib.validate(publishedDefinition) then return definitionLib.copy(publishedDefinition) end
    state.rejected[entry.id] = publishedDefinition
  end
  return definition
end

-- Observers run in blockingOrder, then in catalog order.
local function observationOrder(catalogPosition)
  return function(a, b)
    local aOrder, bOrder = a.blockingOrder or math.huge, b.blockingOrder or math.huge
    if aOrder ~= bOrder then return aOrder < bOrder end
    return catalogPosition[a.id] < catalogPosition[b.id]
  end
end

-- Borrowed buffers are sized to the largest possible result. Their contents stay until that kind is queried again.
local function sizeBlockResults(state)
  for kind, list in pairs(state.blockIndex) do
    local out = state.blockResults[kind]
    local count = #out
    for i = count + 1, #list do out[i] = false end
    for i = #list, count + 1, -1 do out[i] = nil end
  end
end

-- Rebuilds the policy lists: catalog owners in catalog order, then explicit registrations in registration order.
local function buildPolicyIndex(state, host)
  resetPolicyIndex(state)
  local indexing = {seen = {}, catalogPosition = {}, count = 0}
  for _, entry in ipairs(ownerCatalog(state).list) do
    includePolicyDefinition(state, indexing, policyDefinitionFor(state, host, entry))
  end
  for _, id in ipairs(host.list()) do
    if not indexing.seen[id] then includePolicyDefinition(state, indexing, host.get(id)) end
  end
  local before = observationOrder(indexing.catalogPosition)
  for _, list in pairs(state.observationIndex) do table.sort(list, before) end
  sizeBlockResults(state)
  state.indexDirty = false
end

-- Rebuilds the policy index when adoptions changed or the engine revision moved since the last query.
local function refreshPolicyIndex(state)
  local host = currentHost(state)
  local revision = state.revisionOf()
  if state.adoptionRevision ~= revision then
    host = adoptAll(state)
    state.adoptionRevision = revision
  end
  if not state.indexDirty then return end
  buildPolicyIndex(state, host)
end

-- Owner methods -------------------------------------------------------------------------------------

local function addOwnerMethods(access, state)
  function access.register(activityDef)
    local ok, detail = currentHost(state).register(activityDef)
    if ok then state.indexDirty = true end
    return ok, detail
  end

  function access.unregister(id)
    local ok, detail = currentHost(state).unregister(id)
    if ok then state.adopted[id], state.indexDirty, state.adoptionRevision = nil, true, nil end
    return ok, detail
  end

  function access.get(id) return adopt(state, id).get(id) end
  function access.list() return adoptAll(state).list() end
  function access.children(id) return adoptAll(state).children(id) end
  function access.action(id, action, ...) return adopt(state, id).action(id, action, ...) end
  function access.project(id) return adopt(state, id).project(id) end
  function access.isActive(id) return adopt(state, id).isActive(id) end
  function access.canStart(id, otherId) return adopt(state, id).canStart(id, otherId) end
  function access.resources(id) return adopt(state, id).resources(id) end

  -- In-place publication changes can use this signal; engine load, reload and unload already signal it.
  function access.invalidate()
    state.adoptionRevision, state.rejected, state.indexDirty = nil, {}, true
  end

  -- Rescan changed manifests and discard owners removed mid-career.
  function access.modsChanged()
    if not state.opts.catalog then
      -- This refresh also runs independently of career transitions and the manager.
      require('overhaul/lib/platform/manifests').invalidate()
      state.owners = nil
    end
    access.invalidate()
    if not state.host then return end
    local catalog = ownerCatalog(state)
    for id in pairs(state.adopted) do
      if not catalog.byId[id] then drop(state, state.host, id) end
    end
  end
end

-- Policy readers ------------------------------------------------------------------------------------

local function addPolicyMethods(access, state)
  -- Legacy guards stop at the first blocker; their local check sits after negative-order owners.
  function access.isBlocked(kind, localCheck)
    refreshPolicyIndex(state)
    local checkedLocal = false
    for _, definition in ipairs(state.observationIndex[kind] or state.empty) do
      if not checkedLocal and (definition.blockingOrder or math.huge) >= 0 then
        checkedLocal = true
        if localCheck and localCheck() then return true end
      end
      if isBlocking(definition, kind) then return true end
    end
    if not checkedLocal and localCheck then return not not localCheck() end
    return false
  end

  -- Borrowed read-only buffer, overwritten by the next query of this kind; never a snapshot.
  function access.blocking(kind)
    refreshPolicyIndex(state)
    local out = state.blockResults[kind]
    if not out then return state.empty end
    local count = 0
    for _, definition in ipairs(state.blockIndex[kind]) do
      if isBlocking(definition, kind) then
        count = count + 1
        out[count] = definition.id
      end
    end
    for i = #out, count + 1, -1 do out[i] = nil end
    return out
  end

  -- Phone guards historically use truthiness and propagate owner failures.
  function access.phoneRoute()
    refreshPolicyIndex(state)
    for _, definition in ipairs(state.routeIndex) do
      if definition.probe and definition.probe() then return definition.phoneRoute end
    end
  end

  function access.allowPhoneWhileMoving()
    refreshPolicyIndex(state)
    return anyRunning(state.movingIndex)
  end

  function access.blocksTutorialPhone()
    refreshPolicyIndex(state)
    return anyRunning(state.tutorialIndex)
  end

  -- Debug and test access to the current host, with every published owner adopted.
  function access.getHost() return adoptAll(state) end
end

-- Public API ----------------------------------------------------------------------------------------

function M.new(opts)
  opts = opts or {}
  local state = newState(opts)
  state.revisionOf() -- Attach before later owner loads, even before the first policy query.
  local access = {}
  addOwnerMethods(access, state)
  addPolicyMethods(access, state)
  return access
end

-- Consumers may ask before career core publishes its shared access object.
function M.get()
  local career = rawget(_G, 'overhaul_career_career')
  if type(career) == 'table' and career.activity then return career.activity end
  if not shared then shared = M.new() end
  return shared
end

return M
