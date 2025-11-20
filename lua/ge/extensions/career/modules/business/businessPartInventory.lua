local M = {}

local jbeamIO = require('jbeam/io')

local inventory = {}
local businessPartInventoryPath = "business/partInventory.json"
local activeBusinessId = nil

local function getInventory()
  return inventory
end

local function getPartsByModel(model)
  local parts = {}
  for _, part in pairs(inventory) do
    if part.vehicleModel == model then
      table.insert(parts, part)
    end
  end
  return parts
end

local function generatePartId()
  local id = 1
  while inventory[id] do
    id = id + 1
  end
  return id
end

local function addPart(part)
  if not part then return end
  
  local newPart = {
    name = part.name,
    vehicleModel = part.vehicleModel,
    partCondition = deepcopy(part.partCondition or {integrityValue = 1, odometer = 0, visualValue = 1}),
    slot = part.slot or part.slotType -- Try to store slot if available
  }
  
  local id = generatePartId()
  newPart.partId = id
  inventory[id] = newPart
  return id
end

local function addParts(partsList)
  if not partsList then return end
  for _, part in ipairs(partsList) do
    addPart(part)
  end
end

local function removePart(partId)
  if inventory[partId] then
    inventory[partId] = nil
    return true
  end
  return false
end

local function updatePartCondition(partId, condition)
  if inventory[partId] then
    inventory[partId].partCondition = deepcopy(condition)
    return true
  end
  return false
end

local function loadInventory()
  -- Load from save file
  local saveSlot, savePath = career_saveSystem.getCurrentSaveSlot()
  if not saveSlot or not savePath then return end
  
  local data = jsonReadFile(savePath .. "/career/" .. businessPartInventoryPath)
  if data then
    inventory = data
  else
    inventory = {}
  end
end

local function saveInventory()
  local saveSlot, savePath = career_saveSystem.getCurrentSaveSlot()
  if not saveSlot or not savePath then return end
  
  jsonWriteFile(savePath .. "/career/" .. businessPartInventoryPath, inventory, true)
end

local function loadJBeamDataForParts(parts)
  local jBeamPartInfos = {}
  local vehicleModels = {}

  for _, part in pairs(parts) do
    if part.vehicleModel then
      vehicleModels[part.vehicleModel] = true
    end
  end

  for vehicleModel, _ in pairs(vehicleModels) do
    local vehicleDir = string.format("/vehicles/%s/", vehicleModel)
    if FS:directoryExists(vehicleDir) then
      local vehicleFolders = {vehicleDir, "/vehicles/common/"}
      local ioCtx = jbeamIO.startLoading(vehicleFolders)
      jBeamPartInfos[vehicleModel] = jbeamIO.getAvailableParts(ioCtx)
    end
  end
  
  return jBeamPartInfos
end

local function getUIData(businessId)
  activeBusinessId = businessId
  
  local uiData = {}
  
  -- Group parts by model
  local partsByModel = {}
  
  -- Cache ioContexts by vehicle model
  local ioContexts = {}
  
  for id, part in pairs(inventory) do
    if not partsByModel[part.vehicleModel] then
      partsByModel[part.vehicleModel] = {}
    end
    
    -- Expand part data using JBeam
    local expandedPart = deepcopy(part)
    
    -- Get or create ioCtx for this vehicle model
    if not ioContexts[part.vehicleModel] then
      local vehicleDir = string.format("/vehicles/%s/", part.vehicleModel)
      if FS:directoryExists(vehicleDir) then
        local vehicleFolders = {vehicleDir, "/vehicles/common/"}
        ioContexts[part.vehicleModel] = jbeamIO.startLoading(vehicleFolders)
      end
    end
    
    local ioCtx = ioContexts[part.vehicleModel]
    local jbeamData = nil
    if ioCtx then
      jbeamData = jbeamIO.getPart(ioCtx, part.name)
    end
    
    if jbeamData then
      -- JBeam data structure:
      -- jbeamData.information = { name = "Nice Name", value = 100, ... }
      -- jbeamData.slotType = "main"
      
      expandedPart.value = jbeamData.information and jbeamData.information.value or 100
      expandedPart.niceName = jbeamData.information and jbeamData.information.name or part.name
      expandedPart.description = expandedPart.niceName -- Fallback/Compatible field

      -- Ensure slot is present if it wasn't stored
      if not expandedPart.slot and jbeamData.slotType then
          expandedPart.slot = jbeamData.slotType
      end
    else
      expandedPart.description = part.name .. " (Unknown)"
      expandedPart.niceName = part.name
      expandedPart.value = 0
    end
    
    -- Get vehicle nice name
    local modelData = core_vehicles.getModel(part.vehicleModel)
    if modelData and modelData.model then

      local brand = modelData.model.Brand or ""
      local name = modelData.model.Name
      expandedPart.vehicleNiceName = (brand .. " " .. name):match("^%s*(.-)%s*$")
    else
      expandedPart.vehicleNiceName = part.vehicleModel
    end

    -- Calculate value with condition
    if career_modules_valueCalculator then
        local baseValue = career_modules_valueCalculator.getPartValue(expandedPart) * 0.9
        
        local resellerLevel = 0
        if businessId and career_modules_business_businessSkillTree then
          resellerLevel = career_modules_business_businessSkillTree.getNodeProgress(businessId, "shop-upgrades", "part-reseller") or 0
        end
        
        expandedPart.finalValue = baseValue * (1 + (0.05 * resellerLevel))
    end

    table.insert(partsByModel[part.vehicleModel], expandedPart)
  end
  
  uiData.partsByModel = partsByModel
  return uiData
end

local function onExtensionLoaded()
  if not career_career.isActive() then return false end
  loadInventory()
end

local function onSaveFinished()
  saveInventory()
end

local function sellPart(partId)
  if not partId then return false, 0 end
  
  local part = inventory[partId]
  if not part then return false, 0 end
  
  local price = 0
  if career_modules_valueCalculator then
    local expandedPart = deepcopy(part)
    local jbeamData = nil
    local vehicleDir = string.format("/vehicles/%s/", part.vehicleModel)
    if FS:directoryExists(vehicleDir) then
      local vehicleFolders = {vehicleDir, "/vehicles/common/"}
      local ioCtx = jbeamIO.startLoading(vehicleFolders)
      if ioCtx then
        jbeamData = jbeamIO.getPart(ioCtx, part.name)
      end
    end
    
    if jbeamData and jbeamData.information then
      expandedPart.value = jbeamData.information.value or 100
      expandedPart.niceName = jbeamData.information.name or part.name
    else
      expandedPart.value = 100
      expandedPart.niceName = part.name
    end
    
    price = career_modules_valueCalculator.getPartValue(expandedPart) or 0
  else
    price = 100
  end
  
  price = price * 0.9
  
  local resellerLevel = 0
  if activeBusinessId and career_modules_business_businessSkillTree then
    resellerLevel = career_modules_business_businessSkillTree.getNodeProgress(activeBusinessId, "shop-upgrades", "part-reseller") or 0
  end
  
  price = price * (1 + (0.05 * resellerLevel))
  
  inventory[partId] = nil
  return true, price
end

local function sellAllParts()
  if not career_modules_valueCalculator then
    return false, 0
  end
  
  local resellerLevel = 0
  if activeBusinessId and career_modules_business_businessSkillTree then
    resellerLevel = career_modules_business_businessSkillTree.getNodeProgress(activeBusinessId, "shop-upgrades", "part-reseller") or 0
  end
  
  local totalPrice = 0
  local partsToRemove = {}
  
  for partId, part in pairs(inventory) do
    if part then
      local expandedPart = deepcopy(part)
      local jbeamData = nil
      local vehicleDir = string.format("/vehicles/%s/", part.vehicleModel)
      if FS:directoryExists(vehicleDir) then
        local vehicleFolders = {vehicleDir, "/vehicles/common/"}
        local ioCtx = jbeamIO.startLoading(vehicleFolders)
        if ioCtx then
          jbeamData = jbeamIO.getPart(ioCtx, part.name)
        end
      end
      
      if jbeamData and jbeamData.information then
        expandedPart.value = jbeamData.information.value or 100
        expandedPart.niceName = jbeamData.information.name or part.name
      else
        expandedPart.value = 100
        expandedPart.niceName = part.name
      end
      
      local price = career_modules_valueCalculator.getPartValue(expandedPart) or 0
      price = price * 0.9
      price = price * (1 + (0.05 * resellerLevel))
      totalPrice = totalPrice + price
      table.insert(partsToRemove, partId)
    end
  end
  
  for _, partId in ipairs(partsToRemove) do
    inventory[partId] = nil
  end
  
  return true, totalPrice
end

local function sellPartsByVehicle(vehicleModel)
  if not vehicleModel or not career_modules_valueCalculator then
    return false, 0
  end
  
  local resellerLevel = 0
  if activeBusinessId and career_modules_business_businessSkillTree then
    resellerLevel = career_modules_business_businessSkillTree.getNodeProgress(activeBusinessId, "shop-upgrades", "part-reseller") or 0
  end
  
  local totalPrice = 0
  local partsToRemove = {}
  
  for partId, part in pairs(inventory) do
    if part and part.vehicleModel == vehicleModel then
      local expandedPart = deepcopy(part)
      local jbeamData = nil
      local vehicleDir = string.format("/vehicles/%s/", part.vehicleModel)
      if FS:directoryExists(vehicleDir) then
        local vehicleFolders = {vehicleDir, "/vehicles/common/"}
        local ioCtx = jbeamIO.startLoading(vehicleFolders)
        if ioCtx then
          jbeamData = jbeamIO.getPart(ioCtx, part.name)
        end
      end
      
      if jbeamData and jbeamData.information then
        expandedPart.value = jbeamData.information.value or 100
        expandedPart.niceName = jbeamData.information.name or part.name
      else
        expandedPart.value = 100
        expandedPart.niceName = part.name
      end
      
      local price = career_modules_valueCalculator.getPartValue(expandedPart) or 0
      price = price * 0.9
      price = price * (1 + (0.05 * resellerLevel))
      totalPrice = totalPrice + price
      table.insert(partsToRemove, partId)
    end
  end
  
  for _, partId in ipairs(partsToRemove) do
    inventory[partId] = nil
  end
  
  return true, totalPrice
end

M.addPart = addPart
M.addParts = addParts
M.removePart = removePart
M.getInventory = getInventory
M.getPartsByModel = getPartsByModel
M.updatePartCondition = updatePartCondition
M.getUIData = getUIData
M.loadInventory = loadInventory
M.saveInventory = saveInventory
M.sellPart = sellPart
M.sellAllParts = sellAllParts
M.sellPartsByVehicle = sellPartsByVehicle

M.onExtensionLoaded = onExtensionLoaded
M.onSaveFinished = onSaveFinished

return M
