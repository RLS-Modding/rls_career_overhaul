-- Route discovery is shared by the Lua route catalog and the phone UI listing.
-- Callers keep their own fallback policy; this scanner keeps no state between calls.
local catalog = require("overhaul/lib/platform/catalog")
local appDiscovery = require("overhaul/lib/phone/appDiscovery")
local routeValidation = require("overhaul/lib/ui/routeValidation")
local M = {dir = "/gameplay/overhaul/ui/routes/"}
M.validateDeclarations = routeValidation.validateDeclarations

local TAG = "overhaul_ui_routeCatalog"
local PHONE_APPS_DIR = "/gameplay/overhaul/phone/apps/"
local DEFAULT_ORDER = 999
local DEFAULT_UI_ORDER = 10000

local function reservedRouteProblem(reservedNames, data)
  for _, route in ipairs(data.uiRoutes or {}) do
    if reservedNames and reservedNames[route.name] ~= nil then
      return "core route name is reserved: " .. route.name
    end
  end
end

-- Returns a reject(file, reason) that keeps the rejection and warns with the caller's logger when it has one.
local function rejectionRecorder(context, rejected)
  local function warn(message)
    if context.warn then context.warn(message) else catalog.warn(TAG, message) end
  end
  return function(file, reason)
    rejected[#rejected + 1] = {file = file, reason = reason}
    warn("Ignoring route manifest " .. file .. ": " .. reason)
  end
end

-- Phone apps come first; a rejected app is recorded like a rejected manifest file.
local function collectPhoneManifests(context, reject, manifests)
  local apps = context.apps or appDiscovery.scan(context)
  for _, app in ipairs(apps) do
    local reason = M.validateDeclarations(app, context.routeHosts) or reservedRouteProblem(context.reservedNames, app)
    local file = PHONE_APPS_DIR .. app.id .. ".json"
    if reason then reject(file, reason)
    else manifests[#manifests + 1] = {data = app, file = file, kind = "phone"} end
  end
end

-- Standalone UI manifests, read in sorted file order; each needs a namespace and a valid declaration.
local function collectUiManifests(context, fs, reader, reject, manifests)
  local files = fs:findFiles(context.dir or M.dir, "*.json", 0, false, false) or {}
  table.sort(files)
  for _, file in ipairs(files) do
    local ok, data = pcall(reader, file)
    local reason
    if ok then reason = catalog.identity(data, file) else reason = tostring(data) end
    if not reason and not catalog.string(data.namespace) then reason = "standalone route manifests need a namespace" end
    if not reason then reason = M.validateDeclarations(data, context.routeHosts) end
    if not reason then reason = reservedRouteProblem(context.reservedNames, data) end
    if reason then reject(file, reason)
    else manifests[#manifests + 1] = {data = data, file = file, kind = "ui"} end
  end
end

local function manifestOrder(manifest)
  return manifest.data.order or DEFAULT_ORDER
end

-- Lower order first, then id and file, so the same inputs always resolve name conflicts the same way.
local function sortManifests(manifests)
  table.sort(manifests, function(a, b)
    if manifestOrder(a) ~= manifestOrder(b) then return manifestOrder(a) < manifestOrder(b) end
    if a.data.id ~= b.data.id then return a.data.id < b.data.id end
    return a.file < b.file
  end)
end

-- A copy of one manifest's route rows in order, so the manifest's own list is never reordered.
local function sortedRows(routes)
  local rows = {}
  for _, route in ipairs(routes) do rows[#rows + 1] = route end
  table.sort(rows, function(a, b)
    if (a.order or DEFAULT_ORDER) ~= (b.order or DEFAULT_ORDER) then
      return (a.order or DEFAULT_ORDER) < (b.order or DEFAULT_ORDER)
    end
    return a.name < b.name
  end)
  return rows
end

local function routePath(route)
  return route.path:sub(1, 1) == "/" and route.path or "/overhaul/" .. route.path
end

-- The first row to claim a name or path wins; later rows that repeat either are rejected with their manifest.
local function collectEntries(manifests, reject)
  local entries, seenNames, seenPaths = {}, {}, {}
  for _, manifest in ipairs(manifests) do
    for _, route in ipairs(sortedRows(manifest.data.uiRoutes or {})) do
      local path = routePath(route)
      if seenNames[route.name] or seenPaths[path] then
        reject(manifest.file, "route name or path conflict: " .. route.name)
      else
        seenNames[route.name], seenPaths[path] = true, true
        local entry = {}
        for key, value in pairs(route) do entry[key] = value end
        entry.id, entry.ownerId, entry.ownerKind = route.name, manifest.data.id, manifest.kind
        entries[#entries + 1] = entry
      end
    end
  end
  return entries
end

local function entryUiOrder(entry)
  return entry.uiOrder or DEFAULT_UI_ORDER
end

local function sortEntries(entries)
  table.sort(entries, function(a, b)
    if entryUiOrder(a) ~= entryUiOrder(b) then return entryUiOrder(a) < entryUiOrder(b) end
    return a.name < b.name
  end)
end

-- Optional context carries the caller's VFS and reader (also used by the frozen test worlds).
-- Nothing from it is retained in the require-cached library.
function M.scan(context)
  context = context or {}
  local fs, reader = context.fs or FS, context.reader or jsonReadFile
  local rejected, manifests = {}, {}
  local reject = rejectionRecorder(context, rejected)
  collectPhoneManifests(context, reject, manifests)
  collectUiManifests(context, fs, reader, reject, manifests)
  sortManifests(manifests)
  local entries = collectEntries(manifests, reject)
  sortEntries(entries)
  return entries, rejected
end

return M
