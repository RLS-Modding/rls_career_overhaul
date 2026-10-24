-- Event-triggered scene visibility, restored when the event releases its assets.
-- Read asset discovery, visibility changes and teardown.
local M = {}

local ActiveAssets = {}
ActiveAssets.__index = ActiveAssets

function ActiveAssets.new()
  local self = setmetatable({}, ActiveAssets)
  self.assets = {} -- Ensure this is always initialized as an empty table
  return self
end

function ActiveAssets:addAssetList(triggerName, newAssets)
  if not self.assets then
    self.assets = {} -- Reinitialize if it's somehow nil
  end
  local assetList = {
    triggerName = triggerName,
    assets = newAssets,
  }

  -- Add the new asset list
  table.insert(self.assets, assetList)

end

function ActiveAssets:hideAssetList(assetList)
  if assetList and assetList.assets then
    for _, asset in ipairs(assetList.assets) do
      if asset then asset:setHidden(true) end
    end
  end
end

function ActiveAssets:hideAllAssets()
  if not self.assets then
    self.assets = {} -- Reinitialize if it's nil
    return
  end
  for _, assetList in ipairs(self.assets) do
    self:hideAssetList(assetList)
  end
  self.assets = {}
end

function ActiveAssets:getOldestAssetList()
  if not self.assets or #self.assets == 0 then return nil end
  return self.assets[1]
end

function ActiveAssets:displayAssets(data)
  if not data or not data.triggerName then return end
  local triggerName = data.triggerName
  if type(data.assets) ~= "table" then
    log("W", "activeAssets", "Event assets unavailable: no asset list for " .. triggerName)
    return
  end
  for _, assetList in ipairs(self.assets) do
    if assetList.triggerName == triggerName then return end
  end
  local newAssets = {}

  for _, assetName in ipairs(data.assets) do
    local asset = scenetree.findObject(assetName)
    if asset then
      asset:setHidden(false)
      table.insert(newAssets, asset)
    else
      log("W", "activeAssets", "Event asset unavailable: " .. tostring(assetName))
    end
  end

  if #newAssets == 0 then return end

  self:addAssetList(triggerName, newAssets)
end

local function onExtensionLoaded() end

M.onExtensionLoaded = onExtensionLoaded
M.ActiveAssets = ActiveAssets

return M
