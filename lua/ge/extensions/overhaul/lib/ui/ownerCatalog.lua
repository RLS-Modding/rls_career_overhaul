-- Owner declarations are discovered through the mounted VFS. Route consumers retain snapshots
-- until mod adoption; legacy menu projections scan at each open. This library retains no state.
local manifests = require("overhaul/lib/platform/manifests")
local catalog = require("overhaul/lib/platform/catalog")
local M = {dir = "/gameplay/overhaul/ui/owners/"}

local coreRouteOwnersFile = M.dir:gsub("/owners/$", "/coreRouteOwners.json")
local LIST_KEYS = {"acquisitions", "routes", "backHandlers", "screens", "pauseActions", "additionalMenuButtons"}

-- Reserved route names: the stock career tree and shipped owner routes, so add-ons cannot claim them.
-- A false owner marks a stock-derived route with no owner declaration; no owner may claim it.
local function reserveStockTree(children, prefix, owners)
  for key, node in pairs(children or {}) do
    local name = prefix .. "." .. key
    owners[name] = false
    reserveStockTree(node.children or node.Children, name, owners)
  end
end

local function coreRouteOwners(ownershipFile)
  local stock = require("ge/extensions/ui/router/routes/career")
  local owners = {overhaul = false}
  reserveStockTree(stock.Children, "overhaul", owners)
  local declared = jsonReadFile(ownershipFile)
  assert(type(declared) == "table", "core route ownership data is missing")
  for name, owner in pairs(declared) do
    assert(type(name) == "string" and type(owner) == "string", "invalid core route ownership")
    owners[name] = owner
  end
  return owners
end

-- Extension names are plain identifiers, so they can also be turned into module paths.
local function extension(name)
  return type(name) == "string" and name:match("^[%w_]+$") ~= nil
end

-- Double underscores stay as one underscore; single underscores become path separators.
local function exists(name)
  if not extension(name) then return false end
  local path = name:gsub("__", "\1"):gsub("_", "/"):gsub("\1", "_")
  return FS:fileExists("/lua/ge/extensions/" .. path .. ".lua")
end

-- A non-empty map from extension name to boolean.
local function modes(value)
  if type(value) ~= "table" or next(value) == nil then return false end
  for name, enabled in pairs(value) do
    if not catalog.id(name) or type(enabled) ~= "boolean" then return false end
  end
  return true
end

-- Each check returns the first problem it finds as a reason, or nil. validate runs them in this order.

local function exportsProblem(data)
  local exports = data.exports or {}
  if type(exports) ~= "table" or exports.namespace ~= nil and type(exports.namespace) ~= "boolean"
    or not manifests.isStringList(exports.aliases or {}, true) then return "invalid exports" end
  for _, alias in ipairs(exports.aliases or {}) do
    if not extension(alias) then return "invalid export alias" end
  end
  if not catalog.list(exports.prefixes or {}) then return "export prefixes must be a list" end
  for _, prefix in ipairs(exports.prefixes or {}) do
    if type(prefix) ~= "table" or not extension(prefix.from) or not extension(prefix.to) then
      return "invalid export prefix"
    end
  end
  return nil
end

local function listsProblem(data)
  for _, key in ipairs(LIST_KEYS) do
    if not catalog.list(data[key] or {}) then return key .. " must be a list" end
  end
  return nil
end

local function pauseActionReferenceProblem(action)
  for _, key in ipairs({"available", "execute"}) do
    local reference = action[key]
    if type(reference) ~= "table" or not exists(reference.owner) or not extension(reference.method)
      or reference.optional ~= nil and type(reference.optional) ~= "boolean" then
      return "invalid pause action reference"
    end
  end
  return nil
end

local function pauseActionsProblem(data)
  for _, action in ipairs(data.pauseActions or {}) do
    if type(action) ~= "table" or not catalog.id(action.id) or not catalog.number(action.order)
      or type(action.button) ~= "table" or action.button.id ~= action.id
      or action.labelKey ~= nil and not catalog.string(action.labelKey) then return "invalid pause action" end
    local problem = pauseActionReferenceProblem(action)
    if problem then return problem end
  end
  return nil
end

-- Legacy menu rows have their own shape and command bytes; providers project them without loading an extension.
local function additionalMenuButtonsProblem(data)
  for _, row in ipairs(data.additionalMenuButtons or {}) do
    if type(row) ~= "table" or not catalog.id(row.id) or not catalog.number(row.order)
      or type(row.provider) ~= "string" or not row.provider:match("^overhaul/[%w_/]+$")
      or not FS:fileExists("/lua/ge/extensions/" .. row.provider .. ".lua") then
      return "invalid additional menu button"
    end
  end
end

local function acquisitionsProblem(data)
  for _, row in ipairs(data.acquisitions or {}) do
    if type(row) ~= "table" or not catalog.id(row.id) or not modes(row.modes)
      or not manifests.isStringList(row.extensions) or not manifests.isStringList(row.release or {}, true)
      or row.namespace ~= nil and type(row.namespace) ~= "boolean" then return "invalid acquisition" end
    if row.stateOwner ~= nil and not exists(row.stateOwner) then return "invalid acquisition state owner" end
    local names = {}
    for _, name in ipairs(row.extensions) do
      if not exists(name) then return "acquisition extension does not exist" end
      names[name] = true
    end
    if row.stateOwner and not names[row.stateOwner] then return "state owner must belong to acquisition" end
    for _, name in ipairs(row.release or {}) do
      if not names[name] then return "release must belong to acquisition" end
    end
  end
  return nil
end

local function luaRouteProblem(route)
  if route.backTarget ~= nil and route.fallbackTarget ~= nil then return "conflicting Back targets" end
  for _, key in ipairs({"onEnter", "onMount", "onLeave"}) do
    local ref = route[key]
    if ref ~= nil and (type(ref) ~= "string" or not ref:match("^[%w_]+%.[%w_]+$")) then
      return "invalid route lifecycle reference"
    end
  end
  return nil
end

local function routesProblem(data)
  for _, row in ipairs(data.routes or {}) do
    if type(row) ~= "table" or not catalog.id(row.name) or not catalog.number(row.order)
      or type(row.meta) ~= "table" or row.overlay ~= nil and type(row.overlay) ~= "boolean" then
      return "invalid Lua route"
    end
    if row.meta.deferAutosave ~= nil and type(row.meta.deferAutosave) ~= "boolean" then
      return "deferAutosave must be boolean"
    end
    local route = row.meta.luaRoute
    if route ~= nil and type(route) ~= "table" then return "luaRoute must be an object" end
    local problem = route and luaRouteProblem(route)
    if problem then return problem end
  end
  return nil
end

local function backHandlersProblem(data)
  for _, row in ipairs(data.backHandlers or {}) do
    if type(row) ~= "table" or not extension(row.id) or not extension(row.method)
      or row.alias ~= nil and not extension(row.alias) then return "invalid back handler" end
  end
  return nil
end

local function screensProblem(data)
  for _, row in ipairs(data.screens or {}) do
    if type(row) ~= "table" or not catalog.id(row.id) or not catalog.id(row.target) then return "invalid screen" end
  end
  return nil
end

-- Returns the owner manifest when it is valid, or nil and the reason it is not.
local function validate(data)
  if not exists(data.id) then return nil, "owner extension does not exist" end
  local problem = exportsProblem(data) or listsProblem(data) or pauseActionsProblem(data) or additionalMenuButtonsProblem(data)
    or acquisitionsProblem(data) or routesProblem(data) or backHandlersProblem(data) or screensProblem(data)
  if problem then return nil, problem end
  return data
end
M.validate = validate

-- Reports a key that an earlier owner holds or this owner already claimed; otherwise claims it for this owner.
local function duplicateReason(target, key, ownKeys)
  if target[key] ~= nil or ownKeys[key] then return "duplicate declaration: " .. key end
  ownKeys[key] = true
end

-- First conflict in one owner's declarations, checked against earlier owners and against the owner itself.
-- claimed.routes and claimed.prefixes hold the names earlier accepted owners declared.
local function ownerConflict(owner, snapshot, claimed)
  local own = {aliases = {}, prefixes = {}, screens = {}, acquisitions = {}, handlers = {},
    handlerNames = {}, routes = {}, menuButtons = {}}
  local reason
  local function claim(target, key, ownKeys)
    reason = reason or duplicateReason(target, key, ownKeys)
  end
  local exports = owner.exports or {}
  for _, alias in ipairs(exports.aliases or {}) do claim(snapshot.aliases, alias, own.aliases) end
  for _, prefix in ipairs(exports.prefixes or {}) do claim(claimed.prefixes, prefix.from, own.prefixes) end
  for _, row in ipairs(owner.screens or {}) do claim(snapshot.screens, row.id, own.screens) end
  for _, row in ipairs(owner.acquisitions or {}) do claim(snapshot.acquisitions, row.id, own.acquisitions) end
  for _, row in ipairs(owner.backHandlers or {}) do
    claim(snapshot.handlers, row.id, own.handlers)
    if row.alias then claim(snapshot.handlerNames, row.alias, own.handlerNames) end
  end
  for _, row in ipairs(owner.routes or {}) do
    local reserved = snapshot.routeOwners[row.name]
    if reserved ~= nil and reserved ~= owner.id then
      reason = reason or "route name is reserved: " .. row.name
    end
    claim(claimed.routes, row.name, own.routes)
  end
  for _, row in ipairs(owner.additionalMenuButtons or {}) do
    claim(snapshot.menuButtonIds, row.id, own.menuButtons)
  end
  return reason
end

-- Records an accepted owner in the snapshot and marks its names as claimed for the rest of the scan.
local function acceptOwner(owner, snapshot, claimed)
  local exports = owner.exports or {}
  local function namespace(name)
    if not claimed.namespaces[name] then
      claimed.namespaces[name] = true
      snapshot.namespaces[#snapshot.namespaces + 1] = name
    end
  end
  if exports.namespace == true then namespace(owner.id) end
  for _, alias in ipairs(exports.aliases or {}) do snapshot.aliases[alias] = owner.id end
  for _, prefix in ipairs(exports.prefixes or {}) do
    claimed.prefixes[prefix.from] = true
    snapshot.prefixes[#snapshot.prefixes + 1] = prefix
  end
  for _, row in ipairs(owner.screens or {}) do snapshot.screens[row.id] = row.target end
  for _, row in ipairs(owner.acquisitions or {}) do
    snapshot.acquisitions[row.id] = row
    if row.namespace ~= false then for _, name in ipairs(row.extensions) do namespace(name) end end
  end
  for _, row in ipairs(owner.backHandlers or {}) do
    snapshot.handlers[row.id] = {owner = owner.id, method = row.method}
    if row.alias then snapshot.handlerNames[row.alias] = row.id end
  end
  for _, row in ipairs(owner.routes or {}) do
    claimed.routes[row.name] = true
    snapshot.routeOwners[row.name] = owner.id
    if row.overlay then snapshot.overlayOwners[row.name] = owner.id end
    local out = row.overlay and snapshot.overlays or snapshot.routes
    out[#out + 1] = row
  end
  for _, row in ipairs(owner.additionalMenuButtons or {}) do snapshot.menuButtonIds[row.id] = true end
end

local function routeOrder(a, b)
  if a.order ~= b.order then return a.order < b.order end
  return a.name < b.name
end

function M.scan()
  local owners, rejected = manifests.scan({dir = M.dir, tag = "overhaul.ui.owners", validate = validate})
  local snapshot = {owners = owners, aliases = {}, handlerNames = {}, handlers = {}, screens = {},
    routes = {}, overlays = {}, acquisitions = {}, namespaces = {}, prefixes = {}, menuButtonIds = {}}
  snapshot.routeOwners = coreRouteOwners(coreRouteOwnersFile)
  snapshot.routeHosts = {overhaul = true}
  snapshot.routeParents = {}
  local function collectHosts(records, parent)
    for _, record in ipairs(records or {}) do
      if parent then snapshot.routeParents[record.name] = parent end
      if record.hostsChildren then snapshot.routeHosts[record.name] = true end
      collectHosts(record.children, record.name)
    end
  end
  local core = assert(jsonReadFile('/gameplay/overhaul/ui/coreUi.json'), 'core UI declarations missing')
  collectHosts(core.roots)
  snapshot.overlayOwners = {}
  local claimed = {routes = {}, prefixes = {}, namespaces = {}}
  local accepted = {}
  for _, owner in ipairs(owners) do
    local reason = ownerConflict(owner, snapshot, claimed)
    if reason then
      rejected[#rejected + 1] = {file = M.dir .. owner.id .. ".json", reason = reason}
      catalog.warn("overhaul.ui.owners", reason)
    else
      accepted[#accepted + 1] = owner
      acceptOwner(owner, snapshot, claimed)
    end
  end
  snapshot.owners = accepted
  table.sort(snapshot.routes, routeOrder)
  table.sort(snapshot.overlays, routeOrder)
  return snapshot, rejected
end

function M.listForUi()
  local ok, snapshot, rejected = pcall(M.scan)
  if not ok then return {entries = {}, rejected = {}, error = tostring(snapshot)} end
  return {entries = snapshot.owners, rejected = rejected}
end

-- The caller supplies its public context. Each provider performs its own gate and live-owner query in order.
function M.additionalMenuButtons(context)
  local rows, buttons = {}, {}
  for _, owner in ipairs(M.scan().owners) do
    for _, row in ipairs(owner.additionalMenuButtons or {}) do rows[#rows + 1] = row end
  end
  table.sort(rows, manifests.byOrderThenId)
  for _, row in ipairs(rows) do
    local button = require(row.provider)(context)
    if button then buttons[#buttons + 1] = button end
  end
  return buttons
end

return M
