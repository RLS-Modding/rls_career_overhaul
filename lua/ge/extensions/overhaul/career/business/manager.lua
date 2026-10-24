-- Business ownership, purchase financing and sale settlement for one career.
-- Read type registration, saved ownership, purchasing, settlement, then lifecycle and public API.
local recordSale = require("overhaul/lib/progression/logbookFeed").register("overhaul.businessSold", {
  title = "Business sold", label = "Business", icon = "garage01"
}, "career/business/manager.lua")

local recordPurchase = require("overhaul/lib/progression/logbookFeed").register("overhaul.businessPurchased", {
  title = "Business purchased", label = "Business", icon = "garage01"
}, "career/business/manager.lua")

local M = {}

local bundles = require("overhaul/lib/business/bundles")
local typeCatalog = require("overhaul/lib/business/typeCatalog")
local saveState = require("overhaul/lib/business/saveState")
local capabilities = require("overhaul/lib/platform/capabilities")

-- Config ------------------------------------------------------------------------------------------

local BUSINESS_LOAN_INSTALLMENTS = 72
local BUSINESS_LOAN_PAYMENT_WORLD_MINUTES = 1440
local DEFAULT_RESALE_FRACTION = 0.70
local SETTLEMENT_COMPARE_KEYS = {
  "baseResaleValue", "assetLiquidationValue", "upgradeLiquidationValue",
  "accountBalance", "loanPayoffAmount", "convertedDebt", "netPayout",
  "grossProceeds", "businessLoanPrincipal"
}

-- State -------------------------------------------------------------------------------------------

local purchasedBusinesses = {}
local purchasedBusinessesOwnershipReady = false
local businessToPurchase = nil
local businessCallbacks = {}
local businessObjects = {}
-- Registrations retain the owner instance so stale unloads cannot remove its replacement.
local businessModules = {}
local typeData = {}
local typeCatalogEntries = nil
local purchaseCapitalInjectionAmount = nil

-- Shared helpers ----------------------------------------------------------------------------------

local function syncBusinessGarages()
  overhaul_career_garage_garageManager.syncBusinessGarages()
end

-- Business types ----------------------------------------------------------------------------------

local function registerBusinessCallback(businessType, callbacks)
  businessCallbacks[businessType] = callbacks or {}
end

local function registerBusiness(businessType, businessObject, businessModule)
  if not businessType or not businessObject then
    return false
  end
  businessObjects[businessType] = businessObject
  if not typeCatalogEntries then
    typeCatalogEntries = typeCatalog.scan and typeCatalog.scan() or {}
  end
  local manifest = typeCatalog.typeData and typeCatalog.typeData(typeCatalogEntries, businessType)
  local capabilities = {}
  for name, value in pairs(businessObject.features or {}) do capabilities[name] = value end
  for name, value in pairs(manifest and manifest.capabilities or {}) do
    if capabilities[name] ~= nil and capabilities[name] ~= value then
      log('W', 'businessManager', 'Manifest capability overrides owner feature: ' .. businessType .. '.' .. name)
    end
    capabilities[name] = value
  end
  typeData[businessType] = {
    module = manifest and manifest.module,
    sections = manifest and manifest.sections,
    capabilities = capabilities,
    features = capabilities,
    towLabel = manifest and manifest.towLabel,
    towPriority = manifest and manifest.towPriority,
    skillNodes = manifest and manifest.skillNodes or {},
  }
  if businessModule ~= nil then
    businessModules[businessType] = businessModule
  end
  return true
end

local function getBusinessModule(businessType)
  if not businessType then
    return nil
  end
  return businessModules[businessType]
end

-- Explicit type identity prevents equal facility ids from selecting the wrong owner.
local function perform(instance, action, payload)
  if type(instance) ~= "table" or not instance.type or instance.id == nil then
    return false
  end
  local owner = getBusinessModule(instance.type)
  local actions = owner and owner.actions
  local fn = type(actions) == "table" and actions[action]
  if type(fn) ~= "function" then return false end
  if payload == nil then payload = {} end
  return fn(instance, payload)
end

local function getBusinessObject(businessType)
  if not businessType then
    return nil
  end
  return businessObjects[businessType]
end

local function getTypeData(businessType)
  return typeData[businessType]
end

-- Teardown is tied to the registering module, so an old load cannot remove its replacement.
local function unregisterBusiness(businessType, owner)
  if owner == nil or businessModules[businessType] ~= owner then return false end
  businessModules[businessType], businessObjects[businessType] = nil, nil
  typeData[businessType], businessCallbacks[businessType] = nil, nil
  typeCatalogEntries = nil
  return true
end

-- Most features require explicit true; opt-out consumers supply their existing default.
local function hasFeature(businessType, featureName, defaultValue)
  local data = typeData[businessType]
  local value = data and data.capabilities[featureName]
  if defaultValue == true then return value ~= false end
  return value == true
end

local function getAllBusinessObjects()
  return businessObjects
end

local function getPurchaseCapitalInjectionAmount(defaultAmount)
  if type(purchaseCapitalInjectionAmount) == "number" then
    return purchaseCapitalInjectionAmount
  end
  return defaultAmount or 0
end

-- Saved ownership ---------------------------------------------------------------------------------

local function loadPurchasedBusinesses()
  purchasedBusinessesOwnershipReady = false
  if not overhaul_career_career.isActive() then return end
  local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
  if not currentSavePath then return end
  
  local filePath = saveState.ownershipFilePath(currentSavePath)
  local data = jsonReadFile(filePath) or {}
  purchasedBusinesses = data.businesses or {}
  purchasedBusinessesOwnershipReady = true
  syncBusinessGarages()

  overhaul_career_business_partInventory.onPurchasedBusinessesOwnershipReady()
end

local function savePurchasedBusinesses(currentSavePath)
  if not currentSavePath then return end
  
  local filePath = saveState.ownershipFilePath(currentSavePath)
  local data = {
    businesses = purchasedBusinesses
  }
  overhaul_career_saveSystem.jsonWriteFileSafe(filePath, data, true)
end

local function isPurchasedBusiness(businessType, businessId)
  if not purchasedBusinesses[businessType] then return false end
  local businessesByType = purchasedBusinesses[businessType]
  local entry = businessesByType[businessId]
  if not (entry == true or type(entry) == "table") then
    local idStr = tostring(businessId)
    entry = businessesByType[idStr]
  end
  if not (entry == true or type(entry) == "table") then
    local idNum = tonumber(businessId)
    if idNum ~= nil then
      entry = businessesByType[idNum]
      if not (entry == true or type(entry) == "table") then
        entry = businessesByType[tostring(idNum)]
      end
    end
  end
  if not (entry == true or type(entry) == "table") then
    local targetNum = tonumber(businessId)
    local targetStr = tostring(businessId)
    for storedId, storedEntry in pairs(businessesByType) do
      if storedEntry == true or type(storedEntry) == "table" then
        local storedStr = tostring(storedId)
        if storedStr == targetStr then
          entry = storedEntry
          break
        end
        if targetNum ~= nil and tonumber(storedId) == targetNum then
          entry = storedEntry
          break
        end
      end
    end
  end
  if entry == true or (type(entry) == "table") then
    return true
  end
  return false
end

local function resolveStoredKey(businessType, businessId)
  local businessesByType = purchasedBusinesses[businessType]
  if not businessesByType or businessId == nil then return nil end
  local function owned(key)
    local e = businessesByType[key]
    return e == true or type(e) == "table"
  end
  if owned(businessId) then return businessId end
  local idStr = tostring(businessId)
  if owned(idStr) then return idStr end
  local idNum = tonumber(businessId)
  if idNum ~= nil and owned(idNum) then return idNum end
  for storedId, _ in pairs(businessesByType) do
    if owned(storedId) and (tostring(storedId) == idStr or (idNum ~= nil and tonumber(storedId) == idNum)) then
      return storedId
    end
  end
  return nil
end

local function getBusinessInfo(businessType, businessId)
  if not purchasedBusinesses[businessType] then return nil end
  local key = resolveStoredKey(businessType, businessId)
  local entry = key ~= nil and purchasedBusinesses[businessType][key] or nil
  if type(entry) == "table" then
    return entry
  elseif entry == true then
    return { name = businessType .. " " .. tostring(businessId) }
  end
  return nil
end

local function setBusinessName(businessType, businessId, name)
  if not businessType or not businessId then return false end
  if not isPurchasedBusiness(businessType, businessId) then return false end
  local newName = (type(name) == "string" and name:match("^%s*(.-)%s*$")) or ""
  if newName == "" then return false end
  if not purchasedBusinesses[businessType] then return false end
  local key = resolveStoredKey(businessType, businessId)
  if key == nil then return false end
  local entry = purchasedBusinesses[businessType][key]
  if type(entry) == "table" then
    entry.name = newName
  else
    purchasedBusinesses[businessType][key] = {
      name = newName,
      mapId = getCurrentLevelIdentifier() or nil
    }
  end
  overhaul_career_saveSystem.saveCurrent()
  return true
end

local function addPurchasedBusiness(businessType, businessId, skipCallback)
  if isPurchasedBusiness(businessType, businessId) then return false end
  local obj = businessObjects[businessType]
  if obj and obj.resetBusinessForSale then obj.resetBusinessForSale(businessId) end
  overhaul_career_business_fleet.clearBusinessInventory(businessId)
  overhaul_career_business_partInventory.clearBusinessParts(businessId)
  overhaul_career_business_skillTree.clearBusinessProgress(businessId)
  if not purchasedBusinesses[businessType] then
    purchasedBusinesses[businessType] = {}
  end
  
  local business = overhaul_world_facilities.getFacility(businessType, businessId)
  local businessName = business and business.name or (businessType .. " " .. businessId)
  local mapId = getCurrentLevelIdentifier() or nil
  
  purchasedBusinesses[businessType][businessId] = {
    name = businessName,
    mapId = mapId
  }

  syncBusinessGarages()
  gameplay_rawPois.clear()

  capabilities.get("businessComputer").setBusinessContext(businessType, businessId)
  
  local shouldCreateBusinessAccount = hasFeature(businessType, "bankAccount", true)
  if shouldCreateBusinessAccount then
    overhaul_career_economy_bank.createBusinessAccount(businessType, businessId, businessName)
  end
  
  if not skipCallback and businessCallbacks[businessType] and businessCallbacks[businessType].onPurchase then
    businessCallbacks[businessType].onPurchase(businessId)
  end
  
end

-- Purchasing --------------------------------------------------------------------------------------

local function showPurchaseBusinessPrompt(businessType, businessId)
  if not overhaul_career_career.isActive() then return end
  local business = overhaul_world_facilities.getFacility(businessType, businessId)
  if not business then return end
  
  businessToPurchase = {
    type = businessType,
    id = businessId,
    facility = business
  }
  
  local price = business.price or 0
  if price == 0 then
    if addPurchasedBusiness(businessType, businessId) ~= false then
      recordPurchase({name = business.name or "Business", money = 0})
    end
    overhaul_career_saveSystem.saveCurrent(nil, {force = true})
    if businessCallbacks[businessType] and businessCallbacks[businessType].onMenuOpen then
      businessCallbacks[businessType].onMenuOpen(businessId)
    end
    return
  end
  
  extensions.ui_router.navigate('purchase-business', {businessType = businessType})
end

local function requestBusinessData()
  if not businessToPurchase then return nil end
  local business = businessToPurchase.facility
  if business then
    local dataGlobalIndex = overhaul_career_economy_globalEconomy.getGlobalIndex() or 1.0
    local businessData = {
      name = business.name,
      price = math.floor((business.price or 0) * dataGlobalIndex),
      description = business.description or "",
      downPayment = math.floor((business.downPayment or 0) * dataGlobalIndex),
      financingAllowed = business.financingAllowed ~= false,
      businessType = businessToPurchase.type,
      businessId = businessToPurchase.id
    }
    return businessData
  end
  return nil
end

local function canPayBusiness()
  if overhaul_career_economy_cheats.isCheatsMode() then
    return true
  end
  if not businessToPurchase then return false end
  local affordGlobalIndex = overhaul_career_economy_globalEconomy.getGlobalIndex() or 1.0
  local cost = math.floor((businessToPurchase.facility.price or 0) * affordGlobalIndex)
  return overhaul_career_economy_playerAttributes.getAttributeValue("money") >= cost
end

local function buyBusiness()
  if businessToPurchase and isPurchasedBusiness(businessToPurchase.type, businessToPurchase.id) then
    businessToPurchase = nil
    return false
  end
  if businessToPurchase then
    local business = businessToPurchase.facility
    local businessGlobalIndex = overhaul_career_economy_globalEconomy.getGlobalIndex() or 1.0
    local price = { money = { amount = math.floor((business.price or 0) * businessGlobalIndex), canBeNegative = false } }
    local success = overhaul_career_economy_payment.pay(price, require("overhaul/lib/finance/metadata").tag({ category = "purchase", label = "Purchased " .. business.name }, "purchase", {locationId = business.id, locationName = business.name, vehicleRelated = false}))
    if success then
      local previousCapitalInjectionAmount = purchaseCapitalInjectionAmount
      purchaseCapitalInjectionAmount = math.floor((business.downPayment or 0) * businessGlobalIndex)
      local setupOk, setupError = pcall(addPurchasedBusiness, businessToPurchase.type, businessToPurchase.id)
      purchaseCapitalInjectionAmount = previousCapitalInjectionAmount
      if not setupOk then
        log("E", "BusinessManager", "Business setup failed, refunding purchase: " .. tostring(setupError))
        local owned = purchasedBusinesses[businessToPurchase.type]
        if owned then
          owned[businessToPurchase.id] = nil
          if not next(owned) then purchasedBusinesses[businessToPurchase.type] = nil end
        end
        overhaul_career_economy_payment.reward({ money = { amount = price.money.amount } }, require("overhaul/lib/finance/metadata").tag({ category = "refund", label = "Refund: " .. business.name }, "refund", {locationId = business.id, locationName = business.name, vehicleRelated = false}), true)
        businessToPurchase = nil
        return false
      end
      recordPurchase({name = business.name, money = -price.money.amount})
      if businessCallbacks[businessToPurchase.type] and businessCallbacks[businessToPurchase.type].onMenuOpen then
        businessCallbacks[businessToPurchase.type].onMenuOpen(businessToPurchase.id)
      end
      overhaul_career_saveSystem.saveCurrent(nil, {force = true})
    end
    businessToPurchase = nil
  end
end

local function cancelBusinessPurchase()
  guihooks.trigger('ChangeState', {state = 'play'})
  businessToPurchase = nil
end

local function canAffordDownPayment()
  if overhaul_career_economy_cheats.isCheatsMode() then
    return true
  end
  if not businessToPurchase then return false end
  if businessToPurchase.facility.financingAllowed == false then return false end
  local downPayGlobalIndex = overhaul_career_economy_globalEconomy.getGlobalIndex() or 1.0
  local downPaymentAmount = math.floor((businessToPurchase.facility.downPayment or 0) * downPayGlobalIndex)
  if downPaymentAmount <= 0 then return false end
  return overhaul_career_economy_playerAttributes.getAttributeValue("money") >= downPaymentAmount
end

local function financeBusiness()
  if not businessToPurchase then return false end
  if isPurchasedBusiness(businessToPurchase.type, businessToPurchase.id) then
    businessToPurchase = nil
    return false
  end
  local business = businessToPurchase.facility
  if business.financingAllowed == false then
    log("W", "BusinessManager", "Rejected financing for outright-only business " .. tostring(businessToPurchase.id))
    return false
  end
  local financeGlobalIndex = overhaul_career_economy_globalEconomy.getGlobalIndex() or 1.0
  local downPaymentAmount = math.floor((business.downPayment or 0) * financeGlobalIndex)
  local totalPrice = math.floor((business.price or 0) * financeGlobalIndex)
  
  if not canAffordDownPayment() then
    return false
  end
  
  local remainingAmount = totalPrice - downPaymentAmount
  
  local downPaymentPrice = { money = { amount = downPaymentAmount, canBeNegative = false } }
  local success = overhaul_career_economy_payment.pay(downPaymentPrice, require("overhaul/lib/finance/metadata").tag({ category = "purchase", label = "Down payment for " .. business.name }, "purchase", {locationId = business.id, locationName = business.name, vehicleRelated = false}))
  if not success then
    return false
  end
  
  addPurchasedBusiness(businessToPurchase.type, businessToPurchase.id, true)
  
  local businessAccount = nil
  businessAccount = overhaul_career_economy_bank.getBusinessAccount(businessToPurchase.type, businessToPurchase.id)
  
  if remainingAmount > 0 and businessAccount then
    local businessAccountId = businessAccount.id
    -- Daily installments give the business a full operating cycle to earn each payment.
    overhaul_career_economy_loans.takeLoan("moneyGrabBusiness", remainingAmount, BUSINESS_LOAN_INSTALLMENTS, 0, true, businessAccountId, BUSINESS_LOAN_PAYMENT_WORLD_MINUTES)
  end
  
  if businessCallbacks[businessToPurchase.type] and businessCallbacks[businessToPurchase.type].onPurchase then
    local previousCapitalInjectionAmount = purchaseCapitalInjectionAmount
    purchaseCapitalInjectionAmount = downPaymentAmount
    businessCallbacks[businessToPurchase.type].onPurchase(businessToPurchase.id)
    purchaseCapitalInjectionAmount = previousCapitalInjectionAmount
  end
  
  if businessCallbacks[businessToPurchase.type] and businessCallbacks[businessToPurchase.type].onMenuOpen then
    businessCallbacks[businessToPurchase.type].onMenuOpen(businessToPurchase.id)
  end
  
  recordPurchase({name = business.name, money = -downPaymentAmount,
    detail = business.name .. " / Financed; down payment"})
  overhaul_career_saveSystem.saveCurrent(nil, {force = true})
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
  local business = overhaul_world_facilities.getFacility(businessType, businessId)
  if business then
    return business.businessGarageId
  end
  return nil
end

local function getBusinessAccountId(businessType, businessId)
  return "business_" .. tostring(businessType) .. "_" .. tostring(businessId)
end

-- Sale settlement ---------------------------------------------------------------------------------

local function getIndexedBusinessPrice(business)
  local globalIndex = overhaul_career_economy_globalEconomy.getGlobalIndex() or 1.0
  return math.floor((business and business.price or 0) * globalIndex)
end

local function getBusinessLoansForAccount(accountId)
  local loans = {}
  local total = 0
  for _, loan in ipairs(overhaul_career_economy_loans.getActiveLoans() or {}) do
    if loan.businessAccountId == accountId then
      local principal = tonumber(loan.principalOutstanding) or 0
      total = total + principal
      table.insert(loans, loan)
    end
  end
  return loans, math.floor(total + 0.5)
end

local function buildSaleSettlementQuote(businessType, businessId, business)
  local businessObj = businessObjects[businessType]
  local indexedPrice = getIndexedBusinessPrice(business)
  local resaleMultiplier = businessObj and tonumber(businessObj.resaleMultiplier) or DEFAULT_RESALE_FRACTION
  local baseResaleValue = math.floor(indexedPrice * math.max(0, resaleMultiplier))
  local assetLiquidationValue = 0
  if businessObj and businessObj.getLiquidationValue then
    assetLiquidationValue = math.floor((businessObj.getLiquidationValue(businessId) or 0) + 0.5)
  end
  local upgradeLiquidationValue = 0
  upgradeLiquidationValue = math.floor((overhaul_career_business_skillTree.getLiquidationValue(businessType, businessId) or 0) + 0.5)

  local accountId = getBusinessAccountId(businessType, businessId)
  local account = overhaul_career_economy_bank.getBusinessAccount(businessType, businessId) or nil
  local accountBalance = account
    and ((overhaul_career_economy_bank.getBusinessAccountLiquidationBalance(accountId))
      or overhaul_career_economy_bank.getAccountBalance(accountId) or 0)
    or 0
  accountBalance = math.floor(accountBalance + 0.5)
  local positiveAccountBalance = math.max(0, accountBalance)
  local negativeAccountDebt = math.max(0, -accountBalance)
  local grossProceeds = math.max(0, baseResaleValue + assetLiquidationValue + upgradeLiquidationValue + positiveAccountBalance)

  local businessLoans, businessLoanPrincipal = getBusinessLoansForAccount(accountId)
  local availableAfterAccountDebt = math.max(0, grossProceeds - negativeAccountDebt)
  local convertedAccountDebt = math.max(0, negativeAccountDebt - grossProceeds)
  local loanPayoffAmount = math.min(availableAfterAccountDebt, businessLoanPrincipal)
  local convertedLoanPrincipal = math.max(0, businessLoanPrincipal - loanPayoffAmount)
  local netPayout = math.max(0, availableAfterAccountDebt - businessLoanPrincipal)

  return {
    success = true,
    businessType = businessType,
    businessId = businessId,
    businessName = business.name or (businessType .. " " .. tostring(businessId)),
    accountId = accountId,
    indexedPrice = indexedPrice,
    baseResaleValue = baseResaleValue,
    assetLiquidationValue = assetLiquidationValue,
    upgradeLiquidationValue = upgradeLiquidationValue,
    accountBalance = accountBalance,
    positiveAccountBalance = positiveAccountBalance,
    negativeAccountDebt = negativeAccountDebt,
    grossProceeds = grossProceeds,
    businessLoanPrincipal = businessLoanPrincipal,
    loanPayoffAmount = loanPayoffAmount,
    convertedLoanPrincipal = convertedLoanPrincipal,
    convertedAccountDebt = convertedAccountDebt,
    convertedDebt = convertedLoanPrincipal + convertedAccountDebt,
    netPayout = netPayout,
    loans = businessLoans,
  }
end

local function getSaleSettlementQuote(businessType, businessId)
  if not businessType or not businessId then return {success = false, error = "missing_business"} end
  if not isPurchasedBusiness(businessType, businessId) then return {success = false, error = "not_owned"} end
  local business = overhaul_world_facilities.getFacility(businessType, businessId)
  if not business then return {success = false, error = "business_not_found"} end
  local blocked = bundles.saleBlockReason(bundles.forBusiness(businessType, businessId))
  if blocked then return {success = false, error = "bundle_in_use", message = blocked} end
  return buildSaleSettlementQuote(businessType, businessId, business)
end

local function removePurchasedBusiness(businessType, businessId)
  if not purchasedBusinesses[businessType] then return false end
  purchasedBusinesses[businessType][businessId] = nil
  purchasedBusinesses[businessType][tostring(businessId)] = nil
  local idNum = tonumber(businessId)
  if idNum ~= nil then
    purchasedBusinesses[businessType][idNum] = nil
  end
  if not next(purchasedBusinesses[businessType]) then
    purchasedBusinesses[businessType] = nil
  end
  return true
end

local function settlementTermsMatch(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  if tostring(a.businessType or "") ~= tostring(b.businessType or "") then return false end
  if tostring(a.businessId or "") ~= tostring(b.businessId or "") then return false end
  if tostring(a.accountId or "") ~= tostring(b.accountId or "") then return false end
  for _, key in ipairs(SETTLEMENT_COMPARE_KEYS) do
    if math.floor(tonumber(a[key]) or 0) ~= math.floor(tonumber(b[key]) or 0) then
      return false
    end
  end
  return true
end

local function publishSaleResult(businessType, businessId, quote, loanSettlement, paidLoans, payout, convertedDebt)
  guihooks.trigger("toastrMsg", {
    type = "success",
    title = "Business Sold",
    msg = string.format("Sold %s. Paid $%d toward business debt, paid you $%d, converted $%d to personal debt.",
      tostring(quote.businessName or "business"), math.floor(paidLoans + 0.5), payout, math.floor(convertedDebt + 0.5))
  })
  guihooks.trigger('business:sold', {
    businessType = businessType,
    businessId = businessId,
    payout = payout,
    convertedDebt = math.floor(convertedDebt + 0.5),
    loanSettlement = loanSettlement,
  })
  guihooks.trigger('ChangeState', {state = 'play'})
end

local function sellBusiness(businessType, businessId, expectedQuote)
  local quote = getSaleSettlementQuote(businessType, businessId)
  if not quote.success then return quote end
  if expectedQuote ~= nil and not settlementTermsMatch(quote, expectedQuote) then
    return {
      success = false,
      error = "settlement_changed",
      message = "The sale amount changed. Review the updated settlement and confirm again.",
      quote = quote
    }
  end
  local blocked = bundles.saleBlockReason(bundles.forBusiness(businessType, businessId))
  if blocked then return {success = false, error = "bundle_in_use", message = blocked} end

  local proceedsAfterAccountDebt = math.max(0, quote.grossProceeds - quote.negativeAccountDebt)
  local accountDebtShortfall = math.max(0, quote.negativeAccountDebt - quote.grossProceeds)
  local loanSettlement = overhaul_career_economy_loans.settleBusinessLoans(quote.accountId, proceedsAfterAccountDebt)
  local remainingAvailable = loanSettlement and (loanSettlement.remainingAvailable or 0) or proceedsAfterAccountDebt

  if accountDebtShortfall > 0 then
    overhaul_career_economy_loans.createPersonalDebtLoan("moneyGrabBusiness", accountDebtShortfall, BUSINESS_LOAN_INSTALLMENTS, 0)
  end

  if remainingAvailable > 0 then
    overhaul_career_economy_payment.reward({
      money = { amount = math.floor(remainingAvailable + 0.5) }
    }, require("overhaul/lib/finance/metadata").tag({category = "sale",
      label = "Sold " .. (quote.businessName or "business")
    }, "sale", {locationId = businessId, locationName = quote.businessName, vehicleRelated = false}), true)
  end

  local businessObj = businessObjects[businessType]
  if businessObj and businessObj.resetBusinessForSale then
    businessObj.resetBusinessForSale(businessId)
  end

  overhaul_career_business_skillTree.clearBusinessProgress(businessId)

  overhaul_career_economy_bank.liquidateBusinessAccount(quote.accountId)

  removePurchasedBusiness(businessType, businessId)
  syncBusinessGarages()

  gameplay_rawPois.clear()
  local computer = capabilities.peek("businessComputer")
  if computer then computer.clearBusinessContext(businessId) end

  recordSale({name = quote.businessName or "Business", money = math.floor(remainingAvailable + 0.5),
    detail = (quote.businessName or "Business") .. " / Net sale proceeds"})
  overhaul_career_saveSystem.saveCurrent()

  local convertedDebt = (loanSettlement and loanSettlement.convertedPrincipal or quote.convertedLoanPrincipal or 0) + accountDebtShortfall
  local paidLoans = loanSettlement and loanSettlement.paidOffPrincipal or quote.loanPayoffAmount or 0
  local payout = math.floor(remainingAvailable + 0.5)

  publishSaleResult(businessType, businessId, quote, loanSettlement, paidLoans, payout, convertedDebt)

  quote.loanSettlement = loanSettlement
  quote.netPayout = payout
  quote.convertedDebt = math.floor(convertedDebt + 0.5)
  return quote
end

-- Lifecycle ---------------------------------------------------------------------------------------

local function onCareerActivated()
  typeCatalogEntries = nil
  loadPurchasedBusinesses()
end

local function clearTypeCatalog()
  typeCatalogEntries = nil
end

local function onOverhaulSaveCurrentProfile(currentSavePath)
  if not purchasedBusinessesOwnershipReady then loadPurchasedBusinesses() end
  if not purchasedBusinessesOwnershipReady then return end
  savePurchasedBusinesses(currentSavePath)
end

local function getAllPurchasedBusinesses()
  return purchasedBusinesses
end

local function isBusinessOwnershipReady()
  if not overhaul_career_career.isActive() then
    return false
  end
  return purchasedBusinessesOwnershipReady == true
end

-- Vehicle service gates ---------------------------------------------------------------------------

local function dynoBusinessType(businessId)
  local normalizedId = tostring(businessId)
  for businessType in pairs(M.getAllBusinessObjects()) do
    local purchased = M.getPurchasedBusinesses(businessType)
    if purchased[businessId] or purchased[normalizedId] then return businessType end
  end
end

local function dynoPowerReadAllowed(businessId)
  local businessType = dynoBusinessType(businessId)
  local data = typeData[businessType]
  local reference = data and data.skillNodes.dyno
  local skills = overhaul_career_business_skillTree
  if not skills then return false end
  local level = reference and (skills.getNodeProgress(businessId, reference.tree, reference.node) or 0) or 0
  return level ~= 0 or hasFeature(businessType, "dynoPowerReadWithoutSkill")
end

local function towVehicleBusinessId(vehId)
  local fleet = capabilities.get("businessVehicles")
  if not vehId or not fleet then return nil end
  local businessId, vehicleId = fleet.getBusinessVehicleFromSpawnedId(vehId)
  if not businessId or not vehicleId then return nil end
  local vehicles = fleet.getBusinessVehicles(businessId)
  if not vehicles then return nil end
  vehicleId = tonumber(vehicleId) or vehicleId
  for _, vehicle in ipairs(vehicles) do
    if (tonumber(vehicle.vehicleId) or vehicle.vehicleId) == vehicleId then return businessId end
  end
end

local function towBusinessType(businessId)
  local candidates = {}
  for businessType in pairs(businessObjects) do
    if hasFeature(businessType, "towDestination") then
      candidates[#candidates + 1] = {type = businessType, priority = typeData[businessType].towPriority or 999}
    end
  end
  table.sort(candidates, function(left, right)
    if left.priority ~= right.priority then return left.priority < right.priority end
    return left.type < right.type
  end)
  for _, candidate in ipairs(candidates) do
    if M.getPurchasedBusinesses(candidate.type)[businessId] then return candidate.type end
  end
end

local function towingLevel(vehId)
  local skills = overhaul_career_business_skillTree
  if not skills then return 0 end
  local businessId = towVehicleBusinessId(vehId)
  if not businessId or not towBusinessType(businessId) then return 0 end
  -- Existing saves may keep the towing upgrade in either tree; the shop tree wins.
  local level = skills.getNodeProgress(businessId, "shop-upgrades", "towing") or 0
  if level == 0 then level = skills.getNodeProgress(businessId, "qol", "towing") or 0 end
  return level
end

-- Public API --------------------------------------------------------------------------------------

M.registerBusinessCallback = registerBusinessCallback
M.registerBusiness = registerBusiness
M.unregisterBusiness = unregisterBusiness
M.getBusinessObject = getBusinessObject
M.getBusinessModule = getBusinessModule
M.perform = perform
M.hasFeature = hasFeature
M.getTypeData = getTypeData
M.getAllBusinessObjects = getAllBusinessObjects
M.getPurchaseCapitalInjectionAmount = getPurchaseCapitalInjectionAmount
M.isPurchasedBusiness = isPurchasedBusiness
M.getBusinessInfo = getBusinessInfo
M.setBusinessName = setBusinessName
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
M.isBusinessOwnershipReady = isBusinessOwnershipReady
M.getBusinessGarageId = getBusinessGarageId
M.requestBusinessSaleData = getSaleSettlementQuote
M.sellBusiness = sellBusiness
M.dynoPowerReadAllowed = dynoPowerReadAllowed
M.towingLevel = towingLevel

-- Game hooks --------------------------------------------------------------------------------------

M.onCareerActivated = onCareerActivated
M.onExtensionUnloaded = clearTypeCatalog
M.onOverhaulActive = function(active) if not active then clearTypeCatalog() end end
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile

return M
