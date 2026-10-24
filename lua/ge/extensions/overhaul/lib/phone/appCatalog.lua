-- Phone app catalog: finds the apps mods ship (gameplay/overhaul/phone/apps/*.json, read here, and
-- ui/ui-vue/mods/<mod>/phoneApps/*.js, listed here for the UI) and derives channels, dock and home.
local appDiscovery = require("overhaul/lib/phone/appDiscovery")
local M = {}

M.dir = appDiscovery.dir
M.uiModsDir = "/ui/ui-vue/mods/"

local LOG_TAG = appDiscovery.logTag
local PENDING_MODES = { queue = true, drop = true, perEntity = true }
local DOCK_SLOTS = 4
local HOME_SLOTS = 16
local UNORDERED = 999

local function warn(message)
  log("W", LOG_TAG, message)
end

local function isNonEmptyString(value)
  return type(value) == "string" and value ~= ""
end

local function isInteger(value)
  return type(value) == "number" and value % 1 == 0
end

local function validChannels(app)
  local out = {}
  if type(app.notifications) ~= "table" then return out end
  for _, decl in ipairs(app.notifications) do
    if type(decl) == "table" and isNonEmptyString(decl.key) and isNonEmptyString(decl.label) then
      out[#out + 1] = decl
    end
  end
  return out
end

local function dockSlot(app)
  local slot = app.defaultDock
  if isInteger(slot) and slot >= 0 and slot < DOCK_SLOTS then return slot end
  return nil
end

local function byNumberThenId(field)
  return function(a, b)
    if a[field] ~= b[field] then return a[field] < b[field] end
    return a.id < b.id
  end
end

-- Keeps no state, so callers cache what they derive.
function M.scan()
  return appDiscovery.scan({ phoneDir = M.dir, fs = FS, reader = jsonReadFile, warn = warn })
end

local function addScript(out, seen, file)
  file = string.gsub(file, "\\", "/")
  local name = string.lower(string.match(file, "([^/]+)$") or "")
  if string.sub(name, -3) == ".js" and name ~= "index.js" and not seen[string.lower(file)] then
    seen[string.lower(file)] = true
    out[#out + 1] = file
  end
end

-- Paths of every old-format manifest, sorted; the UI imports them in this order. Matches the stock UI
-- mod loader: one recursive search, filtered to <mod>/phoneApps/<file>.js.
function M.scanScripts()
  local out, seen = {}, {}
  for _, file in ipairs(FS:findFiles(M.uiModsDir, "*.js", -1, false, false) or {}) do
    if string.match(string.gsub(file, "\\", "/"), "^/ui/ui%-vue/mods/[^/]+/phoneApps/[^/]+$") then
      addScript(out, seen, file)
    end
  end
  table.sort(out)
  return out
end

local function scanUiRoutes(apps, owners)
  return require("overhaul/lib/ui/routeDiscovery").scan({
    apps = apps, fs = FS, reader = jsonReadFile, reservedNames = owners.routeOwners, routeHosts = owners.routeHosts, warn = warn,
  })
end

-- The single UI entry point (bngApi.engineLua). Never raises: an error comes back as data so the
-- UI promise always settles.
function M.listForUi()
  local ok, apps, rejected = pcall(M.scan)
  if not ok then return { apps = {}, scripts = {}, rejected = {}, error = tostring(apps) } end
  local okScripts, scripts = pcall(M.scanScripts)
  if not okScripts then return { apps = apps, scripts = {}, rejected = rejected, error = tostring(scripts) } end
  local okOwners, owners = pcall(function() return require("overhaul/lib/ui/ownerCatalog").scan() end)
  local okRoutes, routes, routeRejected = pcall(function()
    if not okOwners then error(owners) end
    return scanUiRoutes(apps, owners)
  end)
  return {
    apps = apps,
    scripts = scripts,
    rejected = rejected,
    routes = okRoutes and routes or nil,
    uiOwners = okOwners and owners.owners or nil,
    routeRejected = okRoutes and routeRejected or {},
    routeError = not okRoutes and tostring(routes) or nil,
  }
end

-- Notification routing per channel: first app by id wins, and pending modes are recorded.
local function registerChannels(result, app)
  for _, decl in ipairs(validChannels(app)) do
    if result.channelApps[decl.key] == nil then
      result.channelApps[decl.key] = app.id
      if decl.pending == "drop" then
        result.neverQueue[decl.key] = true
      elseif decl.pending == "perEntity" then
        result.perEntity[decl.key] = true
      elseif decl.pending ~= nil and not PENDING_MODES[decl.pending] then
        warn(string.format("%s: unknown pending mode for %s", app.id, decl.key))
      end
    else
      warn(string.format("%s: notification key %s already belongs to %s", app.id, decl.key, result.channelApps[decl.key]))
    end
  end
end

local function registerInstallSync(result, app)
  local sync = app.onInstall
  if type(sync) == "table" and isNonEmptyString(sync.extension) and isNonEmptyString(sync.call) then
    result.installSync[app.id] = {
      extension = sync.extension,
      call = sync.call,
      loadOnlyInCareer = sync.loadOnlyInCareer == true,
    }
  end
end

-- Declared order on the page, then position, then id.
local function dockOrder(app)
  local page = isInteger(app.defaultPage) and app.defaultPage or UNORDERED
  local position = isInteger(app.defaultPosition) and app.defaultPosition or UNORDERED
  return page * 1000 + position
end

local function homePlacement(app)
  local placement = app.defaultHome
  if type(placement) == "table" and isInteger(placement.slot) and placement.slot >= 0 and placement.slot < HOME_SLOTS then
    return { id = app.id, slot = placement.slot, required = placement.required == true }
  end
  return nil
end

-- Slot i holds the first docked app in order; later claims of a slot are reported.
local function fillDock(result, docked)
  for slot = 1, DOCK_SLOTS do result.dockIds[slot] = "" end
  for _, entry in ipairs(docked) do
    local index = entry.slot + 1
    if result.dockIds[index] == "" then
      result.dockIds[index] = entry.id
    else
      warn(string.format("%s: dock slot %d already belongs to %s (declared order, then id)", entry.id, entry.slot, result.dockIds[index]))
    end
  end
end

-- Manifest order decides channel ownership, installation policy and the first occupant of each dock slot.

function M.derive(apps)
  local result = {
    channelApps = {}, neverQueue = {}, perEntity = {}, installSync = {},
    systemIds = {}, dockIds = {}, defaultHome = {},
  }
  local system, docked, home = {}, {}, {}
  for _, app in ipairs(apps or {}) do
    registerChannels(result, app)
    registerInstallSync(result, app)
    if app.systemApp == true then
      system[#system + 1] = { id = app.id, order = dockSlot(app) or DOCK_SLOTS }
    end
    if dockSlot(app) then
      docked[#docked + 1] = { id = app.id, slot = dockSlot(app), order = dockOrder(app) }
    end
    local placement = homePlacement(app)
    if placement then home[#home + 1] = placement end
  end

  table.sort(system, byNumberThenId("order"))
  for _, entry in ipairs(system) do result.systemIds[#result.systemIds + 1] = entry.id end
  table.sort(docked, byNumberThenId("order"))
  fillDock(result, docked)
  table.sort(home, byNumberThenId("slot"))
  result.defaultHome = home
  return result
end

return M
