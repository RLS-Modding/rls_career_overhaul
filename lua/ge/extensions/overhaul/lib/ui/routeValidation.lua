-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- Shared route declarations must validate identically for phone and standalone manifests.
-- validateDeclarations returns the first problem as a reason string, or nil when every route is valid.
local catalog = require("overhaul/lib/platform/catalog")
local M = {}

-- An object has only string keys, so it cannot be a list.
local function object(value)
  if type(value) ~= "table" then return false end
  for key in pairs(value) do if type(key) ~= "string" then return false end end
  return true
end

-- Returns the first problem with one route row, or nil.
local function routeProblem(data, route, routeHosts)
  if type(route) ~= "table" or not catalog.id(route.name) then return "invalid route name" end
  if not catalog.string(route.path) or route.path:find("..", 1, true) or route.path:find("\\", 1, true)
    or route.path:find("%c") or (route.path:sub(1, 1) == "/" and route.path:sub(1, 10) ~= "/overhaul/") then
    return "invalid route path"
  end
  if not catalog.component(route.component) then return "invalid route component" end
  if route.parent ~= nil and (not catalog.id(route.parent) or routeHosts and not routeHosts[route.parent]) then
    return "unknown route parent: " .. tostring(route.parent)
  end
  if route.backTarget ~= nil and not catalog.id(route.backTarget) then return "invalid Back target" end
  if route.title ~= nil and not catalog.string(route.title) then return "invalid route title" end
  for _, key in ipairs({"order", "uiOrder", "luaOrder"}) do
    if route[key] ~= nil and not catalog.number(route[key]) then return key .. " must be finite" end
  end
  if route.props ~= nil and type(route.props) ~= "boolean" and not object(route.props) then
    return "props must be boolean or an object"
  end
  if route.meta ~= nil and not object(route.meta) then return "meta must be an object" end
  if route.luaMeta ~= nil and not object(route.luaMeta) then return "luaMeta must be an object" end
  if data.namespace and route.name:sub(1, #data.namespace + 1) ~= data.namespace .. "-"
    and route.name:sub(1, #data.namespace + 10) ~= "overhaul." .. data.namespace .. "." then
    return "route name must be namespaced"
  end
  return nil
end

function M.validateDeclarations(data, routeHosts)
  if data.uiRoutes == nil then return end
  if not catalog.list(data.uiRoutes) then return "uiRoutes must be a list" end
  if data.namespace ~= nil and (not catalog.id(data.namespace) or not catalog.string(data.id)
    or data.id:sub(1, #data.namespace + 1) ~= data.namespace .. "-") then return "invalid route namespace" end
  local names, paths = {}, {}
  for _, route in ipairs(data.uiRoutes) do
    local problem = routeProblem(data, route, routeHosts)
    if problem then return problem end
    local path = route.path:sub(1, 1) == "/" and route.path or "/overhaul/" .. route.path
    if names[route.name] or paths[path] then return "duplicate route name or path" end
    names[route.name], paths[path] = true, true
  end
end

return M
