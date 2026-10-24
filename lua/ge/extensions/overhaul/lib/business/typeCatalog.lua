-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- Business type descriptors and tab presentation across mounted mods.
-- Catalog validation keeps add-on tabs from replacing owner policy; scans reject conflicts in order.
local M = {dir = "/gameplay/overhaul/business/types/"}

local catalog = require("overhaul/lib/platform/catalog")

local TAG = "overhaul_business_typeCatalog"

local function validateOwnerPolicy(data)
  if not catalog.list(data.tabs) then return "tabs must be a list" end
  if data.businessType ~= nil and not catalog.id(data.businessType) then return "invalid businessType" end
  if data.businessType ~= nil and (data.module ~= nil or data.capabilities ~= nil or data.skillNodes ~= nil) then
    return "tab extensions cannot replace type owner policy"
  end
  if data.module ~= nil and (not catalog.string(data.module) or not data.module:match("^[%a][%w_]*$")) then
    return "module must be an extension name"
  end
  if data.capabilities ~= nil then
    if type(data.capabilities) ~= "table" then return "capabilities must be an object" end
    for name, value in pairs(data.capabilities) do
      if not catalog.id(name) or type(value) ~= "boolean" then return "capabilities need boolean values" end
    end
  end
  if data.towLabel ~= nil and not catalog.string(data.towLabel) then return "invalid tow label" end
  if data.towPriority ~= nil and not catalog.number(data.towPriority) then return "invalid tow priority" end
  if data.skillNodes ~= nil then
    if type(data.skillNodes) ~= "table" then return "skillNodes must be an object" end
    for name, reference in pairs(data.skillNodes) do
      if not catalog.id(name) or type(reference) ~= "table" or not catalog.id(reference.tree) or not catalog.id(reference.node) then
        return "skillNodes need named tree and node references"
      end
    end
  end
end

local function validateTabs(data, aliases)
  local ids = {}
  for _, tab in ipairs(data.tabs) do
    if type(tab) ~= "table" or not catalog.id(tab.id) or not catalog.string(tab.label) or not catalog.component(tab.component) then
      return "each tab needs id, label and a component path"
    end
    if ids[tab.id] then return "duplicate tab id" end
    ids[tab.id] = true
    if tab.order ~= nil and not catalog.number(tab.order) then return "tab order must be finite" end
    if tab.componentOrder ~= nil and not catalog.number(tab.componentOrder) then return "componentOrder must be finite" end
    if tab.entry ~= nil and type(tab.entry) ~= "boolean" then return "tab entry must be boolean" end
    if tab.data ~= nil and type(tab.data) ~= "table" then return "tab data must be an object" end
    if tab.icon ~= nil and not catalog.string(tab.icon) then return "invalid tab icon" end
    if tab.section ~= nil and not catalog.string(tab.section) then return "invalid tab section" end
    if tab.componentName ~= nil then
      if not catalog.id(tab.componentName) then return "invalid componentName" end
      if aliases[tab.componentName] and aliases[tab.componentName] ~= tab.component then return "conflicting componentName" end
      aliases[tab.componentName] = tab.component
      if data.namespace and tab.componentName:sub(1, #data.namespace + 1) ~= data.namespace .. "-" then return "componentName must be namespaced" end
    end
    if tab.entry and (not catalog.string(data.namespace) or tab.id:sub(1, #data.namespace + 1) ~= data.namespace .. "-") then
      return "new tab ids must start with the manifest namespace and '-'"
    end
  end
end

local function validateViews(data, aliases)
  if data.views ~= nil then
    if not catalog.list(data.views) then return "views must be a list" end
    for _, view in ipairs(data.views) do
      if type(view) ~= "table" or not catalog.id(view.id) or not catalog.component(view.component) then return "invalid view" end
      if view.componentOrder ~= nil and not catalog.number(view.componentOrder) then return "componentOrder must be finite" end
      if aliases[view.id] and aliases[view.id] ~= view.component then return "conflicting view alias" end
      if data.namespace and view.id:sub(1, #data.namespace + 1) ~= data.namespace .. "-" then return "view aliases must be namespaced" end
      aliases[view.id] = view.component
    end
  end
end

local function validateSections(data)
  if data.sections ~= nil then
    if (not catalog.string(data.sourceComponent) and not data.module) or not catalog.list(data.sections) then
      return "sections need a module or sourceComponent and a list"
    end
    local sectionIds = {}
    for _, section in ipairs(data.sections) do
      if type(section) ~= "table" or not catalog.id(section.id) or not catalog.string(section.label) then return "invalid section" end
      if sectionIds[section.id] then return "duplicate section id" end
      sectionIds[section.id] = true
      if section.order ~= nil and not catalog.number(section.order) then return "section order must be finite" end
      if section.icon ~= nil and not catalog.string(section.icon) then return "invalid section icon" end
    end
  end
end

local function validate(data)
  local problem = validateOwnerPolicy(data)
  if problem then return problem end
  local aliases = {}
  problem = validateTabs(data, aliases)
  if problem then return problem end
  problem = validateViews(data, aliases)
  if problem then return problem end
  return validateSections(data)
end

-- The first owner descriptor wins; tab add-ons cannot replace its policy.
function M.typeData(entries, businessType)
  for _, entry in ipairs(entries) do
    if entry.id == businessType then return entry end
  end
  return nil
end

function M.scan()
  local entries, rejected = catalog.scan(M.dir, validate, TAG)
  local result, aliases, tabIds = {}, {}, {}
  for _, entry in ipairs(entries) do
    local candidateAliases, reason = {}, nil
    for _, tab in ipairs(entry.tabs) do if tab.componentName then candidateAliases[tab.componentName] = tab.component end end
    for _, view in ipairs(entry.views or {}) do candidateAliases[view.id] = view.component end
    local aliasNames = {}
    for name in pairs(candidateAliases) do aliasNames[#aliasNames + 1] = name end
    table.sort(aliasNames)
    for _, name in ipairs(aliasNames) do
      local file = candidateAliases[name]
      if aliases[name] and aliases[name] ~= file then reason = "component alias conflict: " .. name; break end
    end
    local businessType = entry.businessType or entry.id
    local seen = tabIds[businessType] or {}
    if not reason then
      for _, tab in ipairs(entry.tabs) do
        if tab.entry and seen[tab.id] then reason = "new tab id conflict: " .. tab.id; break end
      end
    end
    if reason then
      local file = M.dir .. entry.id .. ".json"
      rejected[#rejected + 1] = {file = file, reason = reason}
      catalog.warn(TAG, "Ignoring business type manifest " .. file .. ": " .. reason)
    else
      result[#result + 1] = entry
      for _, name in ipairs(aliasNames) do aliases[name] = candidateAliases[name] end
      tabIds[businessType] = seen
      for _, tab in ipairs(entry.tabs) do if tab.entry then seen[tab.id] = true end end
    end
  end
  return result, rejected
end

function M.listForUi() return catalog.listForUi(M.scan) end
return M
