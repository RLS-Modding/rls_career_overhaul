-- Computer presentation is discovered; original dynamic hooks still own built-in choices.
-- Availability gates inspect built menu data without running unlock code.
local catalog = require("overhaul/lib/platform/catalog")
local M = {dir = "/gameplay/overhaul/computer/functions/"}

local TAG = "overhaul_computer_functionCatalog"

local function validate(data)
  if not catalog.string(data.icon) then return "missing icon name" end
  if data.routeTarget ~= nil and not catalog.string(data.routeTarget) then return "invalid routeTarget" end
  if data.component ~= nil and not catalog.component(data.component) then return "invalid component path" end
  if data.entry ~= nil then
    if data.entry ~= "general" and data.entry ~= "vehicle" then return "entry must be general or vehicle" end
    if not catalog.string(data.label) then return "entry needs a label" end
    if not data.component and not catalog.string(data.routeTarget) then return "entry needs component or routeTarget" end
    if not catalog.string(data.namespace) then return "new entries need a namespace" end
  end
  if data.availability ~= nil then
    local gate = data.availability
    if type(gate) ~= "table" then return "invalid availability gate" end
    for key, value in pairs(gate) do
      if key == "facilityFunction" then
        if not catalog.string(value) then return "invalid facilityFunction" end
      elseif key == "starterVehicle" then
        if type(value) ~= "boolean" then return "invalid starterVehicle gate" end
      else return "unknown availability gate" end
    end
  end
end

function M.scan() return catalog.scan(M.dir, validate, TAG) end
function M.listForUi() return catalog.listForUi(M.scan) end

function M.routeTarget(entry)
  return entry.routeTarget or (entry.component and ("overhaul.computer.function." .. entry.id))
end

function M.registerRoutes(entries, owner)
  local routes = {}
  for _, entry in ipairs(entries) do
    if entry.entry and entry.component and not entry.routeTarget then
      routes[#routes + 1] = {name = M.routeTarget(entry), meta = {
        uiApps = {shown = false}, luaRoute = {backTarget = "overhaul.computer", title = entry.label,
          scopeTree = {root = {preferAutoFocus = true}}},
      }}
    end
  end
  if #routes > 0 then owner.setRoutes("overhaul.computer.functions", routes) end
end

-- Existing hooks keep ownership of built-in choices; discovered entries only add presentation.
function M.addEntries(entries, menuData, functions, navigate)
  for _, entry in ipairs(entries) do
    local gate = entry.availability or {}
    local facility = menuData.computerFacility or {}
    local available = (not gate.facilityFunction or (facility.functions or {})[gate.facilityFunction])
      and (not gate.starterVehicle or menuData.hasBoughtStarterVehicle)
    if entry.entry and available then
      local function add(target, inventoryId)
        if target[entry.id] then
          catalog.warn(TAG, "Computer hook already registered '" .. entry.id .. "'; keeping it")
          return
        end
        local definition = {id = entry.id, label = entry.label, order = entry.order, routeTarget = M.routeTarget(entry)}
        definition.callback = function(computerId)
          navigate(M.routeTarget(entry), {functionId = entry.id, computerId = computerId, inventoryId = inventoryId})
        end
        target[entry.id] = definition
      end
      if entry.entry == "general" then add(functions.general)
      else
        -- Follow the existing garage list, rather than the hash order of vehicleSpecific.
        for _, vehicle in ipairs(menuData.vehiclesInGarage or {}) do
          local inventoryId = vehicle.inventoryId
          local target = functions.vehicleSpecific[inventoryId]
          if target then add(target, inventoryId) end
        end
      end
    end
  end
end

return M
