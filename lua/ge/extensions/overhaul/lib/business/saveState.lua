-- Business persistence keeps the existing profile paths and ownership cleanup.
-- Capture hooks pass their target slot; readers use the selected profile.
local M = {}

local BUSINESSES_DIR = "/career/rls_career/businesses/"

function M.featureFilePath(currentSavePath, fileName)
  return currentSavePath .. "/career/rls_career/" .. fileName
end

function M.ownershipFilePath(currentSavePath)
  return M.featureFilePath(currentSavePath, "businesses.json")
end

function M.businessFilePath(businessId, fileName, currentSavePath)
  if currentSavePath == nil then
    currentSavePath = select(2, overhaul_career_saveSystem.getCurrentProfile())
  end
  if not currentSavePath then return nil end
  return currentSavePath .. BUSINESSES_DIR .. tostring(businessId) .. "/" .. fileName
end

function M.isOwned(businessId, businessType)
  local manager = overhaul_career_business_manager
  if not manager then return false end
  if businessType then return manager.isPurchasedBusiness(businessType, businessId) end
  for kind in pairs(manager.getAllPurchasedBusinesses() or {}) do
    if manager.isPurchasedBusiness(kind, businessId) then return true end
  end
  return false
end

local function nameSet(names)
  local set = {}
  for _, name in ipairs(names) do set[name] = true end
  return set
end

local function idAndName(file, root)
  local relative = file:sub(1, #root) == root and file:sub(#root + 1)
  return (relative or ""):match("^([^/]+)/([^/]+)$")
end

function M.clearUnownedFiles(currentSavePath, names, businessType, writer)
  if not currentSavePath then return end
  local manager = overhaul_career_business_manager
  if not manager or (manager.isBusinessOwnershipReady and not manager.isBusinessOwnershipReady()) then return end
  local root = currentSavePath .. BUSINESSES_DIR
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  local ownedNames = nameSet(names)
  for _, file in ipairs(writer.findFiles(root, "*.json", -1, false, false) or {}) do
    local id, name = idAndName(file, root)
    if id and ownedNames[name] and not M.isOwned(id, businessType) then writer.remove(file) end
  end
end

return M
