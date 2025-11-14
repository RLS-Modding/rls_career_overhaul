local M = {}

M.dependencies = {'career_career', 'career_saveSystem'}

local businessParts = {}

local function getBusinessPartsPath(businessId)
  if not career_career.isActive() then return nil end
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then return nil end
  return currentSavePath .. "/career/rls_career/businesses/" .. businessId .. "/parts.json"
end

local function loadBusinessParts(businessId)
  if not businessId then return {} end
  
  if businessParts[businessId] then
    return businessParts[businessId]
  end
  
  local filePath = getBusinessPartsPath(businessId)
  if not filePath then return {} end
  
  local data = jsonReadFile(filePath) or {}
  businessParts[businessId] = data.parts or {}
  
  return businessParts[businessId]
end

local function saveBusinessParts(businessId, currentSavePath)
  if not businessId or not businessParts[businessId] or not currentSavePath then return end
  
  local filePath = currentSavePath .. "/career/rls_career/businesses/" .. businessId .. "/parts.json"
  
  local dirPath = string.match(filePath, "^(.*)/[^/]+$")
  if dirPath and not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
  
  local data = {
    parts = businessParts[businessId]
  }
  jsonWriteFile(filePath, data, true)
end

local function getBusinessParts(businessId)
  return loadBusinessParts(businessId)
end

local function addPart(businessId, partData)
  if not businessId or not partData then return false end
  
  local parts = loadBusinessParts(businessId)
  
  local partId = partData.partId or ("P" .. string.format("%03d", #parts + 1))
  partData.partId = partId
  partData.addedTime = os.time()
  
  table.insert(parts, partData)
  businessParts[businessId] = parts
  
  return true, partId
end

local function removePart(businessId, partId)
  if not businessId or not partId then return false end
  
  local parts = loadBusinessParts(businessId)
  
  for i, part in ipairs(parts) do
    if part.partId == partId then
      table.remove(parts, i)
      businessParts[businessId] = parts
      return true
    end
  end
  
  return false
end

local function getPartById(businessId, partId)
  local parts = loadBusinessParts(businessId)
  
  for _, part in ipairs(parts) do
    if part.partId == partId then
      return part
    end
  end
  
  return nil
end

local function sellPart(businessId, partId)
  local part = getPartById(businessId, partId)
  if not part then return false, 0 end
  
  local price = part.price or part.value or 0
  local success = removePart(businessId, partId)
  
  return success, price
end

local function getPartsByVehicle(businessId, vehicleModel)
  local parts = loadBusinessParts(businessId)
  local filtered = {}
  
  for _, part in ipairs(parts) do
    if part.compatibleVehicle == vehicleModel or not vehicleModel then
      table.insert(filtered, part)
    end
  end
  
  return filtered
end

local function onCareerActivated()
  businessParts = {}
end

local function onSaveCurrentSaveSlot(currentSavePath)
  for businessId, _ in pairs(businessParts) do
    saveBusinessParts(businessId, currentSavePath)
  end
end

M.onCareerActivated = onCareerActivated
M.getBusinessParts = getBusinessParts
M.addPart = addPart
M.removePart = removePart
M.getPartById = getPartById
M.sellPart = sellPart
M.getPartsByVehicle = getPartsByVehicle
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

return M

