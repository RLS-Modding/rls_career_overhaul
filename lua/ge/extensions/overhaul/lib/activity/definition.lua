-- Activity definitions: validated data that describes an existing owner (job, event, session, business) to the activity host.
-- Every callable field points at the owner's own code; the host only delegates and adds no policy. Reads no game global.
local transitions = require('overhaul/lib/activity/transitions')

local M = {}

M.VERSION = 1
-- Shared names are vocabulary only; owners keep their admission and return semantics.
M.SHIFT_ACTIONS = {start = 'start', admission = 'admission', cancel = 'cancel',
  endShift = 'endShift', guidance = 'guidance', allowsPersonalVehicle = 'allowsPersonalVehicle'}

M.ROLES = {foreground = true, map = true, orchestrator = true, child = true, business = true,
  observer = true, service = true}
M.MODES = {career = true, freeroam = true}
M.RESOURCE_KINDS = {route = true, tasklist = true, hud = true, parking = true, traffic = true,
  input = true, freeze = true, camera = true, timer = true, vehicle = true}
M.BLOCK_KINDS = {travelJournal = true, studioRentals = true}

-- Every field the host accepts (unknown fields are rejected), with its type and meaning.
local FIELDS = {
  id = "string",                        -- unique per host
  label = "string",                     -- for logs and debug UIs
  role = "string",                      -- one of M.ROLES
  parent = "string",                    -- the owning activity; required for a child, forbidden otherwise
  modes = "table",                      -- list of "career" | "freeroam" the owner runs in today
  extension = "string",                 -- owner GE extension; resolved when used, never at require time
  lifecycle = "string",                 -- id of the matching descriptor in tests/fixtures/lifecycle, if any
  actions = "table",                    -- {name = function(payload)}; host.action returns their results unchanged
  state = "function",                   -- read-only projection of the owner's current state
  probe = "function",                   -- true while the owner is running
  canStart = "function",                -- the owner's existing directed start predicate, fn(otherId) -> boolean
  save = "function",                    -- the owner's existing save adapter; the host never writes saves
  restore = "function",                 -- the owner's existing restore adapter
  transitions = "table",                -- {transitionName = function}; names in lib/activity/transitions.lua
  resources = "table",                  -- resource kinds the owner holds today (M.RESOURCE_KINDS)
  settlement = "string",                -- who settles today: "owner", "parent", "observer:<id>" or "none"
  economyKeys = "table",                -- existing economy/section keys the owner pays under
  blocks = "table",                     -- M.BLOCK_KINDS, only where a consumer exists
  blockingProbe = "function",           -- optional blocker predicate, fn(kind) -> boolean; defaults to probe
  phoneRoute = "string",                -- initial phone route while running; first in catalog order wins
  blockingOrder = "number",             -- legacy observation order; negative runs before consumer-local checks
  allowPhoneWhileMoving = "boolean",    -- running owner keeps the existing movement exemption
  blocksTutorialPhone = "boolean",      -- running owner refuses only the tutorial phone
}
M.FIELDS = FIELDS

local function isList(list)
  local count = 0
  for key in pairs(list) do
    if type(key) ~= "number" then return false end
    count = count + 1
  end
  return count == #list
end

local function addError(errors, message)
  errors[#errors + 1] = message
end

local function checkFieldTypes(definition, errors)
  for key, value in pairs(definition) do
    local expected = FIELDS[key]
    if not expected then
      addError(errors, "unknown field " .. tostring(key))
    elseif type(value) ~= expected then
      addError(errors, key .. " must be a " .. expected .. ", got " .. type(value))
    end
  end
end

local function checkIdentity(definition, errors)
  if type(definition.id) ~= "string" or definition.id == "" then addError(errors, "id is required") end
  if type(definition.role) ~= "string" or not M.ROLES[definition.role] then
    addError(errors, "role must be one of the known roles")
  end
  if definition.role == "child" and type(definition.parent) ~= "string" then addError(errors, "a child needs a parent") end
  if definition.role ~= "child" and definition.parent ~= nil then addError(errors, "only a child has a parent") end
  if definition.parent ~= nil and definition.parent == definition.id then
    addError(errors, "an activity cannot be its own parent")
  end
end

local function checkModes(definition, errors)
  if type(definition.modes) ~= "table" then
    addError(errors, "modes is required")
    return
  end
  if not isList(definition.modes) or #definition.modes == 0 then addError(errors, "modes must be a non-empty list") end
  for _, mode in ipairs(definition.modes) do
    if not M.MODES[mode] then addError(errors, "unknown mode " .. tostring(mode)) end
  end
end

local function checkActions(definition, errors)
  if type(definition.actions) ~= "table" then return end
  for name, action in pairs(definition.actions) do
    if type(name) ~= "string" or type(action) ~= "function" then addError(errors, "actions must map names to functions") end
  end
end

local function checkTransitions(definition, errors)
  if type(definition.transitions) ~= "table" then return end
  for name, handler in pairs(definition.transitions) do
    if not transitions.NAMES[name] then addError(errors, "unknown transition " .. tostring(name)) end
    if type(handler) ~= "function" then addError(errors, "transition " .. tostring(name) .. " must be a function") end
  end
end

-- Lists of names: resources, economyKeys and blocks. Resources and blocks also check their vocabulary.
local function checkNameLists(definition, errors)
  for _, listField in ipairs({"resources", "economyKeys", "blocks"}) do
    local list = definition[listField]
    if type(list) == "table" then
      if not isList(list) then addError(errors, listField .. " must be a list") end
      for _, value in ipairs(list) do
        if type(value) ~= "string" then addError(errors, listField .. " entries must be strings") end
        if listField == "resources" and not M.RESOURCE_KINDS[value] then
          addError(errors, "unknown resource kind " .. tostring(value))
        end
        if listField == "blocks" and not M.BLOCK_KINDS[value] then
          addError(errors, "unknown block kind " .. tostring(value))
        end
      end
    end
  end
end

local function checkPhoneAndOrder(definition, errors)
  if definition.phoneRoute == "" then addError(errors, "phoneRoute must not be empty") end
  local order = definition.blockingOrder
  if type(order) == "number" and (order ~= order or math.abs(order) == math.huge) then
    addError(errors, "blockingOrder must be finite")
  end
end

-- Returns true, or false and a list of error strings.
function M.validate(definition)
  if type(definition) ~= "table" then return false, {"definition is not a table"} end
  local errors = {}
  checkFieldTypes(definition, errors)
  checkIdentity(definition, errors)
  checkModes(definition, errors)
  checkActions(definition, errors)
  checkTransitions(definition, errors)
  checkNameLists(definition, errors)
  checkPhoneAndOrder(definition, errors)
  if #errors > 0 then return false, errors end
  return true
end

-- Copy metadata tables without replacing the owner's function references.
function M.copy(definition)
  local out = {}
  for key, value in pairs(definition) do
    if type(value) == "table" then
      local copied = {}
      for innerKey, innerValue in pairs(value) do copied[innerKey] = innerValue end
      out[key] = copied
    else
      out[key] = value
    end
  end
  return out
end

return M
