-- Registers Overhaul's career route tree, feature routes and owner routes with the game's route manager.
-- Entry routes register once and refresh when mods change; source routes follow enable and disable.
local M = {}
local modIdentity = require("overhaul/lib/platform/modIdentity")

local catalog = require("overhaul/lib/platform/catalog")
local discovery = require("overhaul/lib/ui/routeDiscovery")
local ownerCatalog = require("overhaul/lib/ui/ownerCatalog")

M.dependencies = {"ui_router_routeManager"}

-- Config ------------------------------------------------------------------------------------------

-- meta.luaRoute accepts only these keys (ui/router/runtimeRouteRegistry.lua).
local ALLOWED_LUA_ROUTE_KEYS = {screenId = true, title = true, abstract = true, scopeTree = true, backTarget = true,
  fallbackTarget = true, back = true, onEnter = true, onMount = true, onLeave = true, ui = true}

local ENTRY_SOURCE_ID = "overhaul.entry"
local OWNERS_EVENT = "OverhaulUiOwnersChanged"
local DEFAULT_LUA_ORDER = 10000
local HOST_ENTRY_SCOPES = {['phone-shell'] = 'phone-shell'}
local declarations

-- Every owned screen enters its root scope immediately. Explicit scope trees
-- (including an empty tree) remain the route owner's decision.
local function withEntryScope(route)
  route.meta = route.meta or {}
  route.meta.luaRoute = route.meta.luaRoute or {}
  if route.meta.luaRoute.scopeTree == nil then
    local host = route.name
    local parents = declarations and declarations.routeParents or {}
    while host and not HOST_ENTRY_SCOPES[host] do host = parents[host] end
    route.meta.luaRoute.scopeTree = {[host and HOST_ENTRY_SCOPES[host] or 'root'] = {preferAutoFocus = true}}
  end
  return route
end

-- State -------------------------------------------------------------------------------------------

local sources = {}
local sourceOrder = {}
local registered = {}
local entryRouteNames = {}
local enabled = false

-- Career route conversion -------------------------------------------------------------------------

-- A stock career reference becomes an overhaul name: "career" and "career.x" move to the overhaul tree,
-- and owner aliases and prefixes rename the rest.
local function renameRef(value, declarations)
  if type(value) ~= "string" then return value end
  if value == "career" then return "overhaul" end
  local route = string.match(value, "^career%.(.+)$")
  if route then return "overhaul." .. route end
  local module, member = string.match(value, "^(career_[%w_]+)(.*)$")
  if declarations.aliases[module] then return declarations.aliases[module] .. member end
  for _, prefix in ipairs(declarations.prefixes) do
    if value:sub(1, #prefix.from) == prefix.from then return prefix.to .. value:sub(#prefix.from + 1) end
  end
  return value
end

-- Renames a back handler to the owner's handler id, keeping the original when there is no alias.
local function convertBack(back, declarations)
  local result = deepcopy(back)
  if type(result) == "table" and result.handler then
    result.handler = declarations.handlerNames[result.handler] or result.handler
  end
  return result
end

-- Copies only the keys the route registry accepts; references are renamed as they are copied.
local function convert(node, declarations)
  local def = {}
  for key, value in pairs(node) do
    if ALLOWED_LUA_ROUTE_KEYS[key] then
      if key == "screenId" then
        def[key] = declarations.screens[value] or renameRef(value, declarations)
      elseif key == "title" and type(value) == "table" then
        def[key] = deepcopy(value)
        def[key].source = renameRef(value.source, declarations)
      elseif key == "back" then
        def[key] = convertBack(value, declarations)
      elseif type(value) == "string" then
        def[key] = renameRef(value, declarations)
      else
        def[key] = deepcopy(value)
      end
    end
  end
  return def
end

-- Sorted so the route order does not depend on pairs() order.
local function sortedKeys(map)
  local keys = {}
  for key in pairs(map or {}) do table.insert(keys, key) end
  table.sort(keys)
  return keys
end

-- Depth first, so a parent route is listed before its children.
local function walk(children, prefix, out, declarations)
  for _, key in ipairs(sortedKeys(children)) do
    local node = children[key]
    local name = prefix .. "." .. key
    table.insert(out, {name = name, meta = {luaRoute = convert(node, declarations)}})
    walk(node.children or node.Children, name, out, declarations)
  end
end

-- An overlay's luaRoute keys replace the stock ones; its other meta keys are copied whole.
local function mergeOverlay(route, overlay, declarations)
  for key, value in pairs(overlay.meta or {}) do
    if key == "luaRoute" then
      for routeKey, routeValue in pairs(value) do
        local rewritten = routeKey == "back" and convertBack(routeValue, declarations) or deepcopy(routeValue)
        route.meta.luaRoute[routeKey] = rewritten
      end
    else
      route.meta[key] = deepcopy(value)
    end
  end
end

-- An overlay for a route that is not accepted for its owner is dropped with a warning.
-- An accepted overlay merges into its stock route, or becomes a new route when there is none.
local function applyOverlay(overlay, routes, byName, acceptedOverlays, declarations)
  local route = byName[overlay.name]
  local owner = declarations.overlayOwners[overlay.name]
  local accepted = acceptedOverlays[overlay.name]
  if not owner or declarations.routeOwners[overlay.name] ~= owner or not accepted then
    catalog.warn("overhaul.ui.owners", "ignoring unowned route overlay: " .. overlay.name)
  elseif route then
    mergeOverlay(route, accepted, declarations)
  else
    local copy = deepcopy(accepted)
    local back = copy.meta and copy.meta.luaRoute and copy.meta.luaRoute.back
    if back then copy.meta.luaRoute.back = convertBack(back, declarations) end
    table.insert(routes, copy)
    byName[copy.name] = copy
  end
end

-- Overlay names select metadata from accepted owners; caller-supplied metadata cannot claim a core route.
local function buildCareerRoutes(overlays, declarations)
  declarations = declarations or ownerCatalog.scan()
  local stock = require("ge/extensions/ui/router/routes/career")
  local routes = {{name = "overhaul", meta = {luaRoute = convert(stock.Root or {}, declarations)}}}
  walk(stock.Children, "overhaul", routes, declarations)
  local byName = {}
  for _, route in ipairs(routes) do byName[route.name] = route end
  local acceptedOverlays = {}
  for _, overlay in ipairs(declarations.overlays) do acceptedOverlays[overlay.name] = overlay end
  for _, overlay in ipairs(overlays or {}) do
    applyOverlay(overlay, routes, byName, acceptedOverlays, declarations)
  end
  for _, route in ipairs(routes) do withEntryScope(route) end
  return routes
end

-- Feature route discovery -------------------------------------------------------------------------

local function scanFeatureRoutes(context)
  context = context or {}
  local scanContext = {}
  for key, value in pairs(context) do scanContext[key] = value end
  scanContext.dir = discovery.dir
  return discovery.scan(scanContext)
end

local function featureLuaRoute(entry)
  local luaRoute = {backTarget = entry.backTarget or "play", title = entry.title}
  local meta = {infoBar = {visible = false, showSysInfo = false}, topBar = {visible = false},
    uiApps = {shown = false}, luaRoute = luaRoute}
  for key, value in pairs(entry.luaMeta or {}) do meta[key] = value end
  -- Phone app routes share their host's scope rather than mounting a root.
  -- Keep explicit trees (including opt-outs) authoritative for add-on widgets.
  if entry.ownerKind == "phone" and (entry.parent == nil or entry.parent == "phone-shell") then
    meta.luaRoute = meta.luaRoute or {}
    if meta.luaRoute.scopeTree == nil then
      meta.luaRoute.scopeTree = {[HOST_ENTRY_SCOPES['phone-shell']] = {preferAutoFocus = true}}
    end
  end
  return withEntryScope({name = entry.name, meta = meta})
end

local function listForUi()
  return catalog.listForUi(function()
    local owners = ownerCatalog.scan()
    return scanFeatureRoutes({reservedNames = owners.routeOwners, routeHosts = owners.routeHosts})
  end)
end

-- Source validation and registration ---------------------------------------------------------------

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = copy(item) end
  return result
end

-- Nested children must be lists too, so a route tree is only stored when every level is well formed.
local function validRoutes(routes)
  if type(routes) ~= "table" then return false end
  local count = 0
  for key, route in pairs(routes) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or type(route) ~= "table" then return false end
    if route.name ~= nil and (type(route.name) ~= "string" or not route.name:match("^overhaul%.")) then return false end
    if route.children ~= nil and not validRoutes(route.children) then return false end
    count = count + 1
  end
  return count == #routes
end

-- A missing manager, or a call that fails or returns no success, counts as a failed registration.
local function callManager(method, sourceId, routes)
  if not ui_router_routeManager or type(ui_router_routeManager[method]) ~= "function" then return false end
  local ok, result = pcall(ui_router_routeManager[method], sourceId, routes)
  if not ok or type(result) ~= "table" or result.success ~= true then
    log("E", "overhaul_ui_routes", method .. " failed for " .. sourceId)
    return false
  end
  return true
end

local function rememberEntryNames(routes)
  entryRouteNames = {}
  for _, route in ipairs(routes) do entryRouteNames[route.name] = true end
end

-- Owner overlays for the stock career routes, copied so the snapshot cannot be changed through them.
local function overlayRows()
  local overlays = {}
  for _, row in ipairs(declarations.overlays) do
    overlays[#overlays + 1] = {name = row.name, meta = copy(row.meta)}
  end
  return overlays
end

-- Owner routes and feature routes in the order the route manager receives them.
local function sortedEntries()
  local entries = {}
  for _, row in ipairs(declarations.routes) do
    entries[#entries + 1] = {name = row.name, order = row.order, ownerRoute = row}
  end
  for _, entry in ipairs(scanFeatureRoutes({reservedNames = declarations.routeOwners, routeHosts = declarations.routeHosts})) do
    entries[#entries + 1] = {name = entry.name, order = entry.luaOrder or DEFAULT_LUA_ORDER, feature = entry}
  end
  table.sort(entries, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.name < b.name
  end)
  return entries
end

-- The stock-route guard and the per-item lookup run in this order, as they always have.
local function appendEntryRoute(routes, declaration, retainedNames)
  if declaration.feature and declarations.routeOwners[declaration.name] ~= nil then
    log("W", "overhaul_ui_routes", "core route name is reserved: " .. declaration.name)
  elseif not ui_router_routeManager.getRoute(declaration.name) or retainedNames and retainedNames[declaration.name] then
    local route = declaration.feature and featureLuaRoute(declaration.feature)
    if not route then
      route = {name = declaration.name, meta = {infoBar = {visible = false, showSysInfo = false},
        topBar = {visible = false}, uiApps = {shown = false}}}
      for key, value in pairs(declaration.ownerRoute.meta) do route.meta[key] = copy(value) end
    end
    table.insert(routes, withEntryScope(route))
  end
end

-- The career route tree, Overhaul's custom screens and the Overhaul Manager.
local function buildEntryRoutes(retainedNames)
  declarations = declarations or ownerCatalog.scan()
  local routes = buildCareerRoutes(overlayRows(), declarations)
  for _, declaration in ipairs(sortedEntries()) do
    appendEntryRoute(routes, declaration, retainedNames)
  end
  return routes
end

-- Registered once at load, like vanilla's static career routes.
local function registerEntryRoutes()
  if registered[ENTRY_SOURCE_ID] then return true end
  if not ui_router_routeManager or type(ui_router_routeManager.getRoute) ~= "function" then return false end
  local routes = buildEntryRoutes()
  if not callManager("registerModRoutes", ENTRY_SOURCE_ID, routes) then return false end
  rememberEntryNames(routes)
  registered[ENTRY_SOURCE_ID] = true
  log("I", "overhaul_ui_routes", string.format("Registered %d overhaul UI routes", #routes))
  return true
end

local function removeRegistered(sourceId)
  if not registered[sourceId] then return true end
  if not callManager("unregisterModRoutes", sourceId) then return false end
  registered[sourceId] = nil
  return true
end

-- Stores a source's routes and registers them right away when routes are enabled.
local function setRoutes(sourceId, routes)
  if type(sourceId) ~= "string" or sourceId == "" or sourceId == ENTRY_SOURCE_ID or not validRoutes(routes) then
    return false
  end
  local snapshot = copy(routes)
  if enabled then
    if not callManager("registerModRoutes", sourceId, snapshot) then return false end
    registered[sourceId] = true
  end
  if not sources[sourceId] then sourceOrder[#sourceOrder + 1] = sourceId end
  sources[sourceId] = snapshot
  return true
end

local function removeRoutes(sourceId)
  if sourceId == ENTRY_SOURCE_ID or not sources[sourceId] then return false end
  if not removeRegistered(sourceId) then return false end
  sources[sourceId] = nil
  for index, id in ipairs(sourceOrder) do
    if id == sourceId then table.remove(sourceOrder, index) break end
  end
  return true
end

local function disable()
  enabled = false
  local success = true
  for _, sourceId in ipairs(sourceOrder) do
    if not removeRegistered(sourceId) then success = false end
  end
  return success
end

local function enable()
  if enabled then return true end
  if not registerEntryRoutes() then return false end
  for _, sourceId in ipairs(sourceOrder) do
    if not callManager("registerModRoutes", sourceId, copy(sources[sourceId])) then
      disable()
      return false
    end
    registered[sourceId] = true
  end
  enabled = true
  return true
end

local function onExtensionUnloaded()
  declarations = nil
  local success = disable()
  if not removeRegistered(ENTRY_SOURCE_ID) then success = false end
  entryRouteNames = {}
  return success
end

-- Owner declarations changed: rebuild the entry routes, or keep the previous snapshot if the manager refuses.
local function refreshDeclarations()
  if not registered[ENTRY_SOURCE_ID] then
    declarations = nil
    return registerEntryRoutes()
  end
  local previous = declarations
  declarations = ownerCatalog.scan()
  local routes = buildEntryRoutes(entryRouteNames)
  if callManager("registerModRoutes", ENTRY_SOURCE_ID, routes) then
    rememberEntryNames(routes)
    guihooks.trigger(OWNERS_EVENT, declarations.owners)
    return true
  end
  declarations = previous
  return false
end

-- Public API --------------------------------------------------------------------------------------

M.listForUi = listForUi
M.enable = enable
M.disable = disable
M.setRoutes = setRoutes
M.removeRoutes = removeRoutes
M.registerEntryRoutes = registerEntryRoutes
M.registerRoutes = enable
M.unregisterRoutes = disable

-- Game hooks --------------------------------------------------------------------------------------

M.onModActivated = refreshDeclarations
M.onModDeactivated = function(modData)
  if modIdentity.isOwnMod(modData) then return end
  return refreshDeclarations()
end
M.onExtensionLoaded = registerEntryRoutes
M.onExtensionUnloaded = onExtensionUnloaded

return M
