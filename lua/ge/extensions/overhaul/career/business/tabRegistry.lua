-- Tabs that each business type shows on its computer, sorted by order and then label.
-- Tabs are registered per business type, so one type's clear never touches another's.
local M = {}

local tabsByBusinessType = {}

local function registerTab(businessType, tabData)
  if not businessType or not tabData or not tabData.id then return false end
  tabsByBusinessType[businessType] = tabsByBusinessType[businessType] or {}
  tabsByBusinessType[businessType][tabData.id] = tabData
  return true
end

local function unregisterTab(businessType, tabId)
  if not businessType or not tabId or not tabsByBusinessType[businessType] then return false end
  if tabsByBusinessType[businessType][tabId] == nil then return false end
  tabsByBusinessType[businessType][tabId] = nil
  return true
end

local function clearTabs(businessType)
  if businessType then
    tabsByBusinessType[businessType] = nil
  else
    tabsByBusinessType = {}
  end
end

local function sortTabs(tabs)
  table.sort(tabs, function(a, b)
    local orderA = a.order or 999
    local orderB = b.order or 999
    if orderA ~= orderB then return orderA < orderB end
    return (a.label or "") < (b.label or "")
  end)
  return tabs
end

local function getTabs(businessType)
  if not businessType or not tabsByBusinessType[businessType] then return {} end
  local tabs = {}
  for _, tab in pairs(tabsByBusinessType[businessType]) do
    table.insert(tabs, tab)
  end
  return sortTabs(tabs)
end

local function getTab(businessType, tabId)
  if not businessType or not tabId or not tabsByBusinessType[businessType] then return nil end
  return tabsByBusinessType[businessType][tabId]
end

M.registerTab = registerTab
M.unregisterTab = unregisterTab
M.getTabs = getTabs
M.getTab = getTab
M.clearTabs = clearTabs

return M
