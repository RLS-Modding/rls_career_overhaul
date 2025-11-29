local M = {}

local tabRegistry = {}

local function registerTab(businessType, tabData)
  if not businessType or not tabData or not tabData.id then
    return false
  end
  
  if not tabRegistry[businessType] then
    tabRegistry[businessType] = {}
  end
  
  tabRegistry[businessType][tabData.id] = tabData
  return true
end

local function getTabs(businessType)
  if not businessType then
    return {}
  end
  
  if not tabRegistry[businessType] then
    return {}
  end
  
  local tabs = {}
  for _, tab in pairs(tabRegistry[businessType]) do
    table.insert(tabs, tab)
  end
  
  table.sort(tabs, function(a, b)
    local orderA = a.order or 999
    local orderB = b.order or 999
    if orderA ~= orderB then
      return orderA < orderB
    end
    return (a.label or "") < (b.label or "")
  end)
  
  return tabs
end

local function getTab(businessType, tabId)
  if not businessType or not tabId or not tabRegistry[businessType] then
    return nil
  end
  
  return tabRegistry[businessType][tabId]
end

local function clearTabs(businessType)
  if businessType then
    tabRegistry[businessType] = nil
  else
    tabRegistry = {}
  end
end

M.registerTab = registerTab
M.getTabs = getTabs
M.getTab = getTab
M.clearTabs = clearTabs

return M

