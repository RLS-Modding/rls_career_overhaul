-- Declared extension capabilities, resolved to the live owner on each call so an unloaded or replaced
-- extension is never held. Read the session cache, declarations, then live owner lookup.
local catalog = require("overhaul/lib/platform/catalog")
local optional = require("overhaul/lib/platform/optional")

local M = {dir = "/gameplay/overhaul/capabilities/"}
local declarations = {}

-- Shipped declarations cannot change during a session; mount hooks discard the snapshot.
function M.reset()
  declarations = {}
end

-- The manifest for a capability id, or nil when it is missing, unreadable or malformed.
function M.declaration(id)
  if not catalog.id(id) then return nil end
  local cached = declarations[id]
  if cached ~= nil then return cached or nil end
  declarations[id] = false
  local file = M.dir .. id .. ".json"
  local data = jsonReadFile(file)
  if catalog.identity(data, file) then return nil end
  if type(data.owner) ~= "string" or not data.owner:match("^[%w_]+$") then return nil end
  if data.demandLoad ~= nil and type(data.demandLoad) ~= "boolean" then return nil end
  if data.lifetime ~= nil and data.lifetime ~= "career" then return nil end
  declarations[id] = data
  return data
end

-- Runtime probes must not acquire an unused feature just to discover that it has no active session.
function M.peek(id)
  local declaration = M.declaration(id)
  return declaration and optional(declaration.owner) or nil
end

-- Looked up on every call, so a replaced owner is returned and an unloaded one is never served stale.
function M.get(id)
  local declaration = M.declaration(id)
  if not declaration then return nil end
  local owner = optional(declaration.owner)
  if not owner and declaration.demandLoad then
    local manager = optional("overhaul_shell_extensionManager")
    if manager and not manager.canLoadOwners() then return nil end
    if declaration.lifetime == "career" then
      local career = optional("overhaul_career_career")
      if not career or not career.isActive() then return nil end
    end
    extensions.load(declaration.owner)
    owner = optional(declaration.owner)
    if owner and declaration.lifetime == "career" then
      setExtensionUnloadMode(declaration.owner, "manual")
      extensions.disableSerialization({declaration.owner})
    end
  end
  return owner
end

return M
