local M = {}

M.dependencies = {'career_career', 'freeroam_facilities', 'career_modules_payment', 'career_modules_playerAttributes', 'career_saveSystem', 'career_modules_bank', 'career_modules_loans'}

local purchasedBusinesses = {}
local businessToPurchase = nil
local businessCallbacks = {}
local businessObjects = {}

local function registerBusinessCallback(businessType, callbacks)
  businessCallbacks[businessType] = callbacks or {}
end

local function registerBusiness(businessType, businessObject)
  if not businessType or not businessObject then
    return false
  end
  businessObjects[businessType] = businessObject
  return true
end

local function getBusinessObject(businessType)
  if not businessType then
    return nil
  end
  return businessObjects[businessType]
end

local function hasFeature(businessType, featureName)
  local obj = businessObjects[businessType]
  if not obj or not obj.features then
    return false
  end
  return obj.features[featureName] == true
end

local function getAllBusinessObjects()
  return businessObjects
end

local function loadPurchasedBusinesses()
  if not career_career.isActive() then return end
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then return end
  
  local filePath = currentSavePath .. "/career/rls_career/businesses.json"
  local data = jsonReadFile(filePath) or {}
  purchasedBusinesses = data.businesses or {}
end

local function savePurchasedBusinesses(currentSavePath)
  if not currentSavePath then return end
  
  local filePath = currentSavePath .. "/career/rls_career/businesses.json"
  local data = {
    businesses = purchasedBusinesses
  }
  jsonWriteFile(filePath, data, true)
end

local function isPurchasedBusiness(businessType, businessId)
  if not purchasedBusinesses[businessType] then return false end
  local entry = purchasedBusinesses[businessType][businessId]
  if entry == true or (type(entry) == "table") then
    return true
  end
  return false
end

local function getBusinessInfo(businessType, businessId)
  if not purchasedBusinesses[businessType] then return nil end
  local entry = purchasedBusinesses[businessType][businessId]
  if type(entry) == "table" then
    return entry
  elseif entry == true then
    return { name = businessType .. " " .. businessId }
  end
  return nil
end

local function addPurchasedBusiness(businessType, businessId, skipCallback)
  if not purchasedBusinesses[businessType] then
    purchasedBusinesses[businessType] = {}
  end
  
  local business = freeroam_facilities.getFacility(businessType, businessId)
  local businessName = business and business.name or (businessType .. " " .. businessId)
  local mapId = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
  
  purchasedBusinesses[businessType][businessId] = {
    name = businessName,
    mapId = mapId
  }
  
  if career_modules_business_businessComputer then
    career_modules_business_businessComputer.setBusinessContext(businessType, businessId)
  end
  
  if career_modules_bank then
    career_modules_bank.createBusinessAccount(businessType, businessId, businessName)
  end
  
  if not skipCallback and businessCallbacks[businessType] and businessCallbacks[businessType].onPurchase then
    businessCallbacks[businessType].onPurchase(businessId)
  end
  
  career_saveSystem.saveCurrent()
end

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
    if businessCallbacks[businessType] and businessCallbacks[businessType].onMenuOpen then
      businessCallbacks[businessType].onMenuOpen(businessId)
    end
    return
  end
  
  guihooks.trigger('ChangeState', {state = 'purchase-business', businessType = businessType})
end

local function requestBusinessData()
  if not businessToPurchase then return nil end
  local business = businessToPurchase.facility
  if business then
    local businessData = {
      name = business.name,
      price = business.price or 0,
      description = business.description or "",
      downPayment = business.downPayment or 0,
      businessType = businessToPurchase.type,
      businessId = businessToPurchase.id
    }
    return businessData
  end
  return nil
end

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

local function buyBusiness()
  if businessToPurchase then
    local business = businessToPurchase.facility
    local price = { money = { amount = business.price or 0, canBeNegative = false } }
    local success = career_modules_payment.pay(price, { label = "Purchased " .. business.name })
    if success then
      addPurchasedBusiness(businessToPurchase.type, businessToPurchase.id)
      if businessCallbacks[businessToPurchase.type] and businessCallbacks[businessToPurchase.type].onMenuOpen then
        businessCallbacks[businessToPurchase.type].onMenuOpen(businessToPurchase.id)
      end
    end
    businessToPurchase = nil
  end
end

local function cancelBusinessPurchase()
  guihooks.trigger('ChangeState', {state = 'play'})
  businessToPurchase = nil
end

local function canAffordDownPayment()
  if career_modules_cheats and career_modules_cheats.isCheatsMode() then
    return true
  end
  if not businessToPurchase then return false end
  local downPaymentAmount = businessToPurchase.facility.downPayment or 0
  if downPaymentAmount <= 0 then return false end
  local price = { money = { amount = downPaymentAmount, canBeNegative = false } }
  for currency, info in pairs(price) do
    if not info.canBeNegative and career_modules_playerAttributes.getAttributeValue(currency) < info.amount then
      return false
    end
  end
  return true
end

local function financeBusiness()
  if not businessToPurchase then return false end
  local business = businessToPurchase.facility
  local downPaymentAmount = business.downPayment or 0
  local totalPrice = business.price or 0
  
  if not canAffordDownPayment() then
    return false
  end
  
  local remainingAmount = totalPrice - downPaymentAmount
  
  local downPaymentPrice = { money = { amount = downPaymentAmount, canBeNegative = false } }
  local success = career_modules_payment.pay(downPaymentPrice, { label = "Down payment for " .. business.name })
  if not success then
    return false
  end
  
  addPurchasedBusiness(businessToPurchase.type, businessToPurchase.id, true)
  
  local businessAccount = nil
  if career_modules_bank then
    businessAccount = career_modules_bank.getBusinessAccount(businessToPurchase.type, businessToPurchase.id)
    if businessAccount and downPaymentAmount > 0 then
      career_modules_bank.rewardToAccount({ money = { amount = downPaymentAmount } }, businessAccount.id, "Capital Injection", "Down payment deposit")
    end
  end
  
  if remainingAmount > 0 and career_modules_loans and businessAccount then
    local businessAccountId = businessAccount.id
    career_modules_loans.takeLoan("moneyGrabBusiness", remainingAmount, 72, 0, true, businessAccountId)
  end
  
  if businessCallbacks[businessToPurchase.type] and businessCallbacks[businessToPurchase.type].onPurchase then
    businessCallbacks[businessToPurchase.type].onPurchase(businessToPurchase.id)
  end
  
  if businessCallbacks[businessToPurchase.type] and businessCallbacks[businessToPurchase.type].onMenuOpen then
    businessCallbacks[businessToPurchase.type].onMenuOpen(businessToPurchase.id)
  end
  
  businessToPurchase = nil
  return true
end

local function openBusinessMenu(businessType, businessId)
  if businessCallbacks[businessType] and businessCallbacks[businessType].onMenuOpen then
    businessCallbacks[businessType].onMenuOpen(businessId)
  else
    log("W", "BusinessManager", "No menu callback registered for business type: " .. tostring(businessType))
  end
end

local function getPurchasedBusinesses(businessType)
  return purchasedBusinesses[businessType] or {}
end

local function getBusinessGarageId(businessType, businessId)
  local business = freeroam_facilities.getFacility(businessType, businessId)
  if business then
    return business.businessGarageId
  end
  return nil
end

local function onCareerActivated()
  loadPurchasedBusinesses()
end

local function onCareerModulesActivated()
end

local function onSaveCurrentSaveSlot(currentSavePath)
  savePurchasedBusinesses(currentSavePath)
end

local function getAllPurchasedBusinesses()
  return purchasedBusinesses
end

M.onCareerActivated = onCareerActivated
M.onCareerModulesActivated = onCareerModulesActivated
M.registerBusinessCallback = registerBusinessCallback
M.registerBusiness = registerBusiness
M.getBusinessObject = getBusinessObject
M.hasFeature = hasFeature
M.getAllBusinessObjects = getAllBusinessObjects
M.isPurchasedBusiness = isPurchasedBusiness
M.getBusinessInfo = getBusinessInfo
M.showPurchaseBusinessPrompt = showPurchaseBusinessPrompt
M.requestBusinessData = requestBusinessData
M.canPayBusiness = canPayBusiness
M.canAffordDownPayment = canAffordDownPayment
M.buyBusiness = buyBusiness
M.financeBusiness = financeBusiness
M.cancelBusinessPurchase = cancelBusinessPurchase
M.openBusinessMenu = openBusinessMenu
M.getPurchasedBusinesses = getPurchasedBusinesses
M.getAllPurchasedBusinesses = getAllPurchasedBusinesses
M.getBusinessGarageId = getBusinessGarageId
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

return M

