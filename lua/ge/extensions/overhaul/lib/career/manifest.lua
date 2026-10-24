-- Career module and owner manifests: which extensions are career modules and in what order they load, the
-- shell scopes each owner joins, and the private parts each owner keeps. Read fresh from mod-shipped JSON.
local devScope = require("overhaul/lib/lifecycle/scopes/dev")
local platformManifests = require("overhaul/lib/platform/manifests")

local M = {}

-- Config --------------------------------------------------------------------------------------------

-- Manifest ids and module paths retain the engine extension-name convention.
M.modulesDir = "/gameplay/overhaul/career/modules/"
M.ownersDir = "/gameplay/overhaul/career/owners/"

local MODULE_PATTERN = "^[%w_][%w_/%-]*$"
local LIB_PREFIX = "overhaul/lib/"

-- Scope topology is shell policy; membership and cleanup facts belong to their owners.
local shellScopes = {
  {id = "careerCore", load = "each", seed = false},
  {id = "testerMenu", load = "demand"},
  {id = "editor", load = "demand"},
  {id = "bootManual", load = "modes"},
  {id = "routes", load = "each"},
  {id = "shell", load = "each"},
  {id = "services", load = "each"},
  {id = "vehicleTools", load = "each"},
  {id = "guards", load = "each"},
  {id = "settings", load = "grouped"},
  {id = "late", load = "each"},
  {id = "world", load = "demand"},
  {id = "freeroamEvents", load = "demand"},
  {id = "careerWorld", load = "demand"},
  {id = "owned", load = "demand"},
  {id = "children", load = "parent", seed = false},
}
local shellScopeById = {}
for _, scope in ipairs(shellScopes) do shellScopeById[scope.id] = scope end

-- Owner policies ------------------------------------------------------------------------------------

-- Each owner's modulePolicy merged into one snapshot: private module paths, private folders and career flags.
local function modulePolicies()
  local policies = {privateModules = {}, privateFolders = {}, career = {}}
  for _, owner in ipairs((M.scanOwners())) do
    local policy = owner.modulePolicy or {}
    for _, path in ipairs(policy.privateModules or {}) do policies.privateModules[path] = true end
    for _, folder in ipairs(policy.privateFolders or {}) do
      policies.privateFolders[#policies.privateFolders + 1] = {prefix = folder, owner = owner.module}
    end
    if policy.career ~= nil then policies.career[owner.module] = policy.career end
  end
  return policies
end

-- A caller checking many paths can retain one ownership snapshot for that check.
M.modulePolicies = modulePolicies

-- Module manifests ----------------------------------------------------------------------------------

-- The GE extension name of a module path (extensions.luaPathToExtName).
function M.extensionName(path)
  return (path:gsub("_", "__"):gsub("/", "_"))
end

local function validateModule(data, policy)
  local path = data.module
  if not platformManifests.isNonEmptyString(path) or not string.match(path, MODULE_PATTERN) or string.find(path, "//", 1, true) then
    return nil, "module must be a Lua path under lua/ge/extensions/ (no .lua)"
  end
  if data.id ~= M.extensionName(path) then
    return nil, string.format("id must be the module's extension name %s", M.extensionName(path))
  end
  if M.isPrivateModule(path, policy) then
    return nil, "private helpers must not have career module manifests"
  end
  -- A module whose file no mod ships would be requested and fail to load at every career start.
  if not FS:fileExists("/lua/ge/extensions/" .. path .. ".lua") then
    return nil, string.format("module file /lua/ge/extensions/%s.lua not found", path)
  end
  return {id = data.id, order = data.order, module = path}
end

-- The usable module manifests in load order (order, then id), and the rejected files.
function M.scanModules()
  local policy = modulePolicies()
  return platformManifests.scan({dir = M.modulesDir, tag = "overhaul_career_manifest",
    validate = function(data) return validateModule(data, policy) end})
end

-- Read the folder on every call so mounted add-ons are observed without a central roster.
function M.discoverModules()
  local modules, demand = {}, {}
  for index, entry in ipairs((M.scanModules())) do
    modules[index] = entry.module
  end
  for _, owner in ipairs((M.scanOwners())) do
    if owner.demandLoad then demand[owner.module] = {saveFiles = owner.saveFiles or {}} end
  end
  return modules, demand
end

-- Private helpers -----------------------------------------------------------------------------------

-- Debug panels only load with the dev key.
M.isDebugModule = devScope.isDebugModule

-- Stop at the nearest enclosing extension to identify its private parts.
local function hasParentExtension(path)
  local prefix, depth = "", 0
  for segment in path:gmatch("[^/]+") do
    depth = depth + 1
    if prefix ~= "" and depth > 3 and FS:fileExists("/lua/ge/extensions/" .. prefix .. ".lua") then return true end
    prefix = prefix == "" and segment or prefix .. "/" .. segment
  end
  return false
end

function M.isPrivateModule(path, policy)
  if path:sub(1, #LIB_PREFIX) == LIB_PREFIX then return true end
  policy = policy or modulePolicies()
  if policy.privateModules[path] then return true end
  for _, folder in ipairs(policy.privateFolders) do
    if path ~= folder.owner and path:sub(1, #folder.prefix) == folder.prefix then return true end
  end
  return hasParentExtension(path)
end

function M.requiresManifest(path, roster, policy)
  policy = policy or modulePolicies()
  if M.isPrivateModule(path, policy) then return false end
  if policy.career[path] ~= nil then return policy.career[path] end
  -- Core and demand-loaded extensions have a shell owner rather than a career module owner.
  local name = M.extensionName(path)
  for _, scope in ipairs((roster or M.discoverShell()).scopes) do
    for _, shellName in ipairs(scope) do
      if name == shellName then return false end
    end
  end
  return path:sub(1, #"overhaul/career/") == "overhaul/career/" or M.isDebugModule(path)
end

-- Checks --------------------------------------------------------------------------------------------

-- Validate membership without loading or requiring hook owners.
function M.check(files, directory, modules)
  modules = modules or M.discoverModules()
  local roster, policy = M.discoverShell(), modulePolicies()
  local counts, found = {}, {}
  local unlisted, missing, problems = {}, {}, {}
  for _, path in ipairs(modules) do counts[path] = (counts[path] or 0) + 1 end
  for _, file in ipairs(files or {}) do
    if file:sub(1, #directory) == directory and file:sub(-4) == ".lua" then
      local path = file:sub(#directory + 1, -5)
      found[path] = true
      if M.requiresManifest(path, roster, policy) and not counts[path] then unlisted[#unlisted + 1] = path end
    end
  end
  for path, count in pairs(counts) do
    if not found[path] then missing[#missing + 1] = path end
    if count ~= 1 then problems[#problems + 1] = "Duplicate career module manifest: " .. path end
    if M.isPrivateModule(path, policy) then problems[#problems + 1] = "Private helper has a career module manifest: " .. path end
  end
  table.sort(unlisted)
  table.sort(missing)
  table.sort(problems)
  return unlisted, missing, problems
end

-- Rejected JSON must fail coverage too: discovery deliberately skips broken add-ons at runtime.
function M.validateCoverage(files, directory)
  local entries, rejected = M.scanModules()
  local modules = {}
  for index, entry in ipairs(entries) do modules[index] = entry.module end
  local unlisted, missing, problems = M.check(files, directory, modules)
  for _, entry in ipairs(rejected) do
    problems[#problems + 1] = string.format("Invalid career module manifest %s: %s", entry.file, entry.reason)
  end
  return unlisted, missing, problems
end

-- Owner manifests -----------------------------------------------------------------------------------

-- Scope rows must be a list of known scopes with numeric orders; the rows keep their declared order.
local function validScopeRows(rows, ownerId)
  if type(rows) ~= "table" then return nil, "scopes must be a list" end
  local count = 0
  for key in pairs(rows) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then return nil, "scopes must be a list" end
    count = count + 1
  end
  if count ~= #rows then return nil, "scopes must be a list" end
  local scopes = {}
  for index, row in ipairs(rows) do
    if type(row) ~= "table" or not shellScopeById[row.id] then return nil, "unknown shell scope" end
    if type(row.order) ~= "number" or row.order ~= row.order then return nil, "scope order must be a number" end
    if row.id == "children" then
      if type(row.parent) ~= "string" or not row.parent:match("^[%a_][%w_]*$") or row.parent == ownerId then
        return nil, "children need a different extension parent id"
      end
      if row.preserveOnLoad ~= nil and type(row.preserveOnLoad) ~= "boolean" then
        return nil, "preserveOnLoad must be boolean"
      end
      for _, accepted in ipairs(scopes) do
        if accepted.id == "children" then return nil, "ambiguous child ownership" end
      end
    elseif row.parent ~= nil or row.preserveOnLoad ~= nil then
      return nil, "parent and preserveOnLoad belong only to children"
    end
    scopes[index] = {id = row.id, order = row.order, parent = row.parent, preserveOnLoad = row.preserveOnLoad}
  end
  return scopes
end

-- Input manifest order must survive catalog discovery.
local function validInputActions(input)
  if type(input) ~= "table" or type(input.order) ~= "number" or input.order ~= input.order
    or type(input.path) ~= "string" or not input.path:match("^/lua/ge/extensions/core/input/actions/[%w_%-]+%.json$")
    or not platformManifests.isStringList(input.actions) then
    return nil
  end
  return {order = input.order, path = input.path, actions = input.actions}
end

-- Returns nil when the policy is valid, else the reason. Private paths are module-style, and private folders end in "/".
local function modulePolicyProblem(policy)
  if type(policy) ~= "table" or policy.career ~= nil and type(policy.career) ~= "boolean" then
    return "invalid modulePolicy"
  end
  for _, key in ipairs({"privateModules", "privateFolders"}) do
    if not platformManifests.isStringList(policy[key] or {}, true) then return "invalid " .. key end
    for _, value in ipairs(policy[key] or {}) do
      if not value:match(MODULE_PATTERN) or value:find("//", 1, true)
          or key == "privateFolders" and value:sub(-1) ~= "/" then
        return "invalid private path"
      end
    end
  end
  return nil
end

-- Owner order is required even though other catalogs allow it to be omitted.
local function validateOwner(data)
  local path = data.module
  if not platformManifests.isNonEmptyString(path) or not path:match(MODULE_PATTERN) or path:find("//", 1, true)
    or data.id ~= M.extensionName(path) then
    return nil, "module must match the extension id"
  end
  if not FS:fileExists("/lua/ge/extensions/" .. path .. ".lua") then return nil, "owner module file not found" end
  if data.unload ~= nil and type(data.unload) ~= "boolean" then return nil, "unload must be boolean" end
  if data.demandLoad ~= nil and type(data.demandLoad) ~= "boolean" then return nil, "demandLoad must be boolean" end
  if data.integration ~= nil then
    local integration = data.integration
    if type(integration) ~= "table" or type(integration.global) ~= "string"
      or not integration.global:match("^[%a_][%w_]*$") or type(integration.readyHook) ~= "string"
      or not integration.readyHook:match("^on[%w_]+$") or type(data.scopes) ~= "table" or #data.scopes ~= 0 then
      return nil, "integration needs a global, readyHook and no eager scopes"
    end
  end
  if data.saveFiles ~= nil then
    if not data.demandLoad or not platformManifests.isStringList(data.saveFiles) then return nil, "saveFiles need demandLoad" end
    for _, file in ipairs(data.saveFiles) do
      if file:sub(1, 1) == "/" or file:find("..", 1, true) or file:find(":", 1, true)
          or file:find("\\", 1, true) then return nil, "saveFiles must be relative save paths" end
    end
  end
  for _, key in ipairs({"triggerFacilityTypes", "demandRoutes"}) do
    if data[key] ~= nil then
      if not data.demandLoad or not platformManifests.isStringList(data[key])
        or type(data.capability) ~= "string" or not data.capability:match("^[%w_.%-]+$") then
        return nil, key .. " need a demand capability"
      end
    end
  end
  local scopes, scopeReason = validScopeRows(data.scopes, data.id)
  if not scopes then return nil, scopeReason end
  if data.beforeCareerStop ~= nil and type(data.beforeCareerStop) ~= "boolean" then return nil, "beforeCareerStop must be boolean" end
  if data.beforeUnload ~= nil and (type(data.beforeUnload) ~= "string" or not data.beforeUnload:match("^[%a_][%w_]*$")) then
    return nil, "beforeUnload must be a method name"
  end
  if data.reloadOnReady ~= nil and (type(data.reloadOnReady) ~= "string" or not data.reloadOnReady:match("^[%a_][%w_]*$")) then
    return nil, "reloadOnReady must be a method name"
  end
  local inputActions = nil
  if data.inputActions ~= nil then
    inputActions = validInputActions(data.inputActions)
    if not inputActions then return nil, "invalid inputActions" end
  end
  local policy = data.modulePolicy
  if policy ~= nil then
    local problem = modulePolicyProblem(policy)
    if problem then return nil, problem end
  end
  if data.policyOnly ~= nil and type(data.policyOnly) ~= "boolean" then return nil, "invalid policyOnly" end
  return {id = data.id, order = data.order, module = path, scopes = scopes, unload = data.unload,
    integration = data.integration,
    demandLoad = data.demandLoad, saveFiles = data.saveFiles, capability = data.capability,
    triggerFacilityTypes = data.triggerFacilityTypes,
    demandRoutes = data.demandRoutes,
    modulePolicy = policy, policyOnly = data.policyOnly,
    beforeCareerStop = data.beforeCareerStop, beforeUnload = data.beforeUnload,
    reloadOnReady = data.reloadOnReady, inputActions = inputActions}
end

-- Keep the first valid path; the VFS decides same-path replacement.
function M.scanOwners()
  local owners, rejected = platformManifests.scan({dir = M.ownersDir, tag = "overhaul_career_owners", validate = validateOwner})
  local byId, parents = {}, {}
  for _, owner in ipairs(owners) do
    if not owner.policyOnly then byId[owner.id] = owner end
    for _, row in ipairs(owner.scopes) do
      if row.parent then parents[owner.id] = row.parent end
    end
  end
  local accepted = {}
  for _, owner in ipairs(owners) do
    local parent, seen, reason = parents[owner.id], {[owner.id] = true}, nil
    while parent do
      if not byId[parent] then reason = "orphan child parent"; break end
      if seen[parent] then reason = "cyclic child ownership"; break end
      seen[parent], parent = true, parents[parent]
    end
    if reason then
      rejected[#rejected + 1] = {file = M.ownersDir .. owner.id .. ".json", reason = reason}
      log("W", "overhaul_career_owners", "Ignoring owner " .. owner.id .. ": " .. reason)
    else
      accepted[#accepted + 1] = owner
    end
  end
  return accepted, rejected
end

-- Shell roster --------------------------------------------------------------------------------------

-- An empty roster with one row per shell scope, in the order the shell defines them.
local function newShellRoster()
  local roster = {scopes = {}, byId = {}, byName = {}, declared = {}, owned = {}, seed = {}, inputActions = {}, beforeCareerStop = {}, children = {}, preserved = {}}
  local members = {}
  for _, spec in ipairs(shellScopes) do
    local scope = {id = spec.id, load = spec.load, seed = spec.seed}
    roster.scopes[#roster.scopes + 1] = scope
    roster.byId[scope.id], members[scope.id] = scope, {}
  end
  return roster, members
end

-- Records one owner's names, unload ownership, scope membership, input actions and career-stop hook.
local function addOwnerToRoster(roster, members, owner)
  roster.byName[owner.id], roster.declared[owner.id] = owner, true
  if owner.unload ~= false then roster.owned[owner.id] = true end
  for index, row in ipairs(owner.scopes) do
    local list = members[row.id]
    list[#list + 1] = {id = owner.id, order = row.order, index = index}
    if row.parent then
      local children = roster.children[row.parent] or {}
      roster.children[row.parent] = children
      children[#children + 1] = owner.id
      if row.preserveOnLoad then roster.preserved[owner.id] = true end
    end
    if shellScopeById[row.id].seed ~= false then roster.owned[owner.id], roster.seed[owner.id] = true, true end
  end
  if owner.inputActions then
    local input = owner.inputActions
    roster.inputActions[#roster.inputActions + 1] = {id = owner.id, order = input.order, path = input.path, actions = input.actions}
  end
  if owner.beforeCareerStop then roster.beforeCareerStop[#roster.beforeCareerStop + 1] = owner.id end
end

-- Fills each scope's list with its member ids: by order, then id, then declared position.
local function fillScopeMembers(roster, members)
  for _, scope in ipairs(roster.scopes) do
    local list = members[scope.id]
    table.sort(list, function(left, right)
      if left.order ~= right.order then return left.order < right.order end
      if left.id ~= right.id then return left.id < right.id end
      return left.index < right.index
    end)
    for _, row in ipairs(list) do scope[#scope + 1] = row.id end
  end
end

-- Only accepted owners contribute scope membership and input repair declarations.
function M.discoverShell()
  local roster, members = newShellRoster()
  for _, entry in ipairs((M.scanModules())) do
    roster.declared[entry.id], roster.owned[entry.id] = true, true
  end
  for _, owner in ipairs((M.scanOwners())) do
    if not owner.policyOnly then addOwnerToRoster(roster, members, owner) end
  end
  fillScopeMembers(roster, members)
  table.sort(roster.inputActions, platformManifests.byOrderThenId)
  return roster
end

-- The manager supplies its accepted roster; this lookup never discovers another owner snapshot.
function M.childrenOf(parentId, roster)
  assert(roster, "children lookup needs the accepted manager roster")
  local names, preserved = {}, {}
  if not roster.byName[parentId] then return names, preserved end
  for _, name in ipairs(roster.children[parentId] or {}) do
    names[#names + 1] = name
    if roster.preserved[name] then preserved[name] = true end
  end
  return names, preserved
end

function M.shellScope(id, roster)
  return assert((roster or M.discoverShell()).byId[id], "unknown shell scope " .. tostring(id))
end

-- A new set the caller owns: acquisitions can extend it without mutating a scan result.
function M.shellOwnedSeed(roster)
  local owned = {}
  for name in pairs((roster or M.discoverShell()).seed) do owned[name] = true end
  return owned
end

function M.unloadOwns(name, roster)
  return (roster or M.discoverShell()).owned[name] == true
end

return M
