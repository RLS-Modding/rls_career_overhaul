-- Phone app manifest discovery: reads and validates gameplay/overhaul/phone/apps/*.json, shared by the
-- catalog and the route scans, so neither depends on the UI entry point.
local routeValidation = require("overhaul/lib/ui/routeValidation")
local M = { dir = "/gameplay/overhaul/phone/apps/" }

local LOG_TAG = "overhaul_phone_appCatalog"
local ID_PATTERN = "^[%w][%w%._%-]*$"
local UNLOCK_TYPES = { careerActive = true, optionalFeature = true, businessSkillNode = true, lua = true }

M.logTag = LOG_TAG

local function warn(message)
  log("W", LOG_TAG, message)
end

local function isNonEmptyString(value)
  return type(value) == "string" and value ~= ""
end

local function fileId(file)
  return string.match(file, "([^/\\]+)%.[jJ][sS][oO][nN]$")
end

local function validIcon(icon)
  if isNonEmptyString(icon) then return true end
  if type(icon) ~= "table" or #icon == 0 then return false end
  for _, name in ipairs(icon) do
    if not isNonEmptyString(name) then return false end
  end
  return true
end

local function validRoute(data)
  return isNonEmptyString(data.route) and string.sub(data.route, 1, 1) == "/"
end

local function validComponent(data)
  return isNonEmptyString(data.component) and string.sub(data.component, 1, 1) == "/"
    and string.lower(string.sub(data.component, -4)) == ".vue"
end

-- Required fields and the id/file match. Returns a reason string when the manifest must be rejected.
local function requiredFieldsProblem(data, file)
  local id = data.id
  if not isNonEmptyString(id) or not string.match(id, ID_PATTERN) then return "invalid id" end
  if id ~= fileId(file) then return string.format("id '%s' must match the file name", id) end
  if not isNonEmptyString(data.name) then return "missing name" end
  if not validRoute(data) and not validComponent(data) then return "needs a route or a component (.vue path)" end
  if not (validIcon(data.icon) or isNonEmptyString(data.iconTile) or isNonEmptyString(data.iconImage)) then
    return "needs icon, iconTile or iconImage"
  end
  return nil
end

-- Optional parts that are malformed are reported but do not reject the app: the phone skips them.
local function reportOptionalProblems(data, file, report)
  if data.unlock ~= nil and (type(data.unlock) ~= "table" or not UNLOCK_TYPES[data.unlock.type]) then
    report(string.format("%s: unknown unlock type; the app stays locked", file))
  end
  if data.notifications ~= nil and type(data.notifications) ~= "table" then
    report(string.format("%s: notifications must be a list", file))
  end
end

-- Returns the manifest when it is usable, or nil and the reason.
local function validate(data, file, report)
  if type(data) ~= "table" then return nil, "not a JSON object" end
  local problem = requiredFieldsProblem(data, file)
  if problem then return nil, problem end
  if data.uiRoutes ~= nil then
    local reason = routeValidation.validateDeclarations(data)
    if reason then return nil, reason end
  end
  reportOptionalProblems(data, file, report)
  return data
end

-- Usable manifests sorted by id, plus { file, reason } for every rejected file.
function M.scan(context)
  context = context or {}
  local fs, reader = context.fs or FS, context.reader or jsonReadFile
  local report = context.warn or warn
  local files = fs:findFiles(context.phoneDir or M.dir, "*.json", 0, false, false) or {}
  table.sort(files)
  local apps, rejected, seen = {}, {}, {}
  for _, file in ipairs(files) do
    local ok, data = pcall(reader, file)
    local app, reason
    if ok then app, reason = validate(data, file, report) else reason = tostring(data) end
    if app and seen[app.id] then app, reason = nil, "duplicate id" end
    if app then
      seen[app.id] = true
      apps[#apps + 1] = app
    else
      rejected[#rejected + 1] = { file = file, reason = reason }
      report(string.format("Ignoring phone app manifest %s: %s", file, tostring(reason)))
    end
  end
  table.sort(apps, function(a, b) return a.id < b.id end)
  return apps, rejected
end

return M
