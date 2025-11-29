local M = {}

M.dependencies = {'career_career', 'career_saveSystem', 'freeroam_facilities'}

local function openMenu(businessId)
  guihooks.trigger('ChangeState', {state = 'business-dealership', businessId = businessId})
end

local function onCareerActivated()
  if not career_modules_business_businessManager then return end
  career_modules_business_businessManager.registerBusinessCallback("businessDealership", {
    onPurchase = function(businessId)
      if career_modules_bank then
        local accountId = "business_businessDealership_" .. tostring(businessId)
        career_modules_bank.rewardToAccount({
          money = { amount = 50000 }
        }, accountId, "Business Purchase Reward", "Initial operating capital")
      end
    end,
    onMenuOpen = function(businessId)
      openMenu(businessId)
    end
  })
end

M.onCareerActivated = onCareerActivated
M.openMenu = openMenu

return M

