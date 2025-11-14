local M = {}

M.dependencies = {'career_career', 'freeroam_facilities', 'career_modules_payment', 'career_modules_playerAttributes', 'career_saveSystem', 'career_modules_bank'}

-- Track purchased businesses by business type and ID
-- Structure: purchasedBusinesses[businessType][businessId] = true
local purchasedBusinesses = {}
-- Track current business being purchased: {type, id, facility}
local businessToPurchase = nil
-- Callbacks for business-specific actions: {businessType = {onPurchase = function, onMenuOpen = function}}
local businessCallbacks = {}

-- Register a callback for a business type
local function registerBusinessCallback(businessType, callbacks)
  businessCallbacks[businessType] = callbacks or {}
end

-- Load purchased businesses from save file
local function loadPurchasedBusinesses()
  if not career_career.isActive() then return end
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then return end
  
  local filePath = currentSavePath .. "/career/rls_career/businesses.json"
  local data = jsonReadFile(filePath) or {}
  purchasedBusinesses = data.businesses or {}
end

-- Save purchased businesses to save file
local function savePurchasedBusinesses(currentSavePath)
  if not currentSavePath then return end
  
  local filePath = currentSavePath .. "/career/rls_career/businesses.json"
  local data = {
    businesses = purchasedBusinesses
  }
  jsonWriteFile(filePath, data, true)
end

-- Check if a business is purchased
local function isPurchasedBusiness(businessType, businessId)
  if not purchasedBusinesses[businessType] then return false end
  return purchasedBusinesses[businessType][businessId] or false
end

-- Add a business to purchased list
local function addPurchasedBusiness(businessType, businessId)
  if not purchasedBusinesses[businessType] then
    purchasedBusinesses[businessType] = {}
  end
  purchasedBusinesses[businessType][businessId] = true
  
  -- Create business account
  if career_modules_bank then
    local business = freeroam_facilities.getFacility(businessType, businessId)
    local businessName = business and business.name or (businessType .. " " .. businessId)
    career_modules_bank.createBusinessAccount(businessType, businessId, businessName)
  end
  
  -- Call business-specific callback if registered
  if businessCallbacks[businessType] and businessCallbacks[businessType].onPurchase then
    businessCallbacks[businessType].onPurchase(businessId)
  end
  
  career_saveSystem.saveCurrent()
end

-- Show purchase prompt for a business
local function showPurchaseBusinessPrompt(businessType, businessId)
  if not career_career.isActive() then return end
  local business = freeroam_facilities.getFacility(businessType, businessId)
  if not business then return end
  
  businessToPurchase = {
    type = businessType,
    id = businessId,
    facility = business
  }
  
  local price = business.price or 0
  if price == 0 then
    addPurchasedBusiness(businessType, businessId)
    -- Call menu callback if registered
    if businessCallbacks[businessType] and businessCallbacks[businessType].onMenuOpen then
      businessCallbacks[businessType].onMenuOpen(businessId)
    end
    return
  end
  
  -- Trigger purchase UI state (business-specific)
  guihooks.trigger('ChangeState', {state = 'purchase-business', businessType = businessType})
end

-- Request business data for purchase UI
local function requestBusinessData()
  if not businessToPurchase then return nil end
  local business = businessToPurchase.facility
  if business then
    local businessData = {
      name = business.name,
      price = business.price or 0,
      description = business.description or "",
      businessType = businessToPurchase.type,
      businessId = businessToPurchase.id
    }
    return businessData
  end
  return nil
end

-- Check if player can afford the business purchase
local function canPayBusiness()
  if career_modules_cheats and career_modules_cheats.isCheatsMode() then
    return true
  end
  if not businessToPurchase then return false end
  local price = { money = { amount = businessToPurchase.facility.price or 0, canBeNegative = false } }
  for currency, info in pairs(price) do
    if not info.canBeNegative and career_modules_playerAttributes.getAttributeValue(currency) < info.amount then
      return false
    end
  end
  return true
end

-- Process business purchase
local function buyBusiness()
  if businessToPurchase then
    local business = businessToPurchase.facility
    local price = { money = { amount = business.price or 0, canBeNegative = false } }
    local success = career_modules_payment.pay(price, { label = "Purchased " .. business.name })
    if success then
      addPurchasedBusiness(businessToPurchase.type, businessToPurchase.id)
      -- Call menu callback if registered
      if businessCallbacks[businessToPurchase.type] and businessCallbacks[businessToPurchase.type].onMenuOpen then
        businessCallbacks[businessToPurchase.type].onMenuOpen(businessToPurchase.id)
      end
    end
    businessToPurchase = nil
  end
end

-- Cancel business purchase
local function cancelBusinessPurchase()
  guihooks.trigger('ChangeState', {state = 'play'})
  businessToPurchase = nil
end

-- Open menu for a business (calls business-specific callback)
local function openBusinessMenu(businessType, businessId)
  if businessCallbacks[businessType] and businessCallbacks[businessType].onMenuOpen then
    businessCallbacks[businessType].onMenuOpen(businessId)
  else
    log("W", "BusinessManager", "No menu callback registered for business type: " .. tostring(businessType))
  end
end

-- Get all purchased businesses of a specific type
local function getPurchasedBusinesses(businessType)
  return purchasedBusinesses[businessType] or {}
end

-- Get business garage ID for a business (from facility definition)
local function getBusinessGarageId(businessType, businessId)
  local business = freeroam_facilities.getFacility(businessType, businessId)
  if business then
    return business.businessGarageId
  end
  return nil
end

-- Hook called when career is activated
function M.onCareerActivated()
  loadPurchasedBusinesses()
end

-- Hook called after all modules are activated (for callback registration)
function M.onCareerModulesActivated()
  -- Callbacks can be registered here or in individual business modules' onCareerActivated
end

-- Hook called when saving current save slot
local function onSaveCurrentSaveSlot(currentSavePath)
  savePurchasedBusinesses(currentSavePath)
end

-- Public API
M.registerBusinessCallback = registerBusinessCallback
M.isPurchasedBusiness = isPurchasedBusiness
M.showPurchaseBusinessPrompt = showPurchaseBusinessPrompt
M.requestBusinessData = requestBusinessData
M.canPayBusiness = canPayBusiness
M.buyBusiness = buyBusiness
M.cancelBusinessPurchase = cancelBusinessPurchase
M.openBusinessMenu = openBusinessMenu
M.getPurchasedBusinesses = getPurchasedBusinesses
M.getBusinessGarageId = getBusinessGarageId
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

return M

