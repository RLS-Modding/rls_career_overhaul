-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {'career_career'}

local function canPay(price, accountId)
  if career_modules_cheats and career_modules_cheats.isCheatsMode() then
    return true
  end
  
  if accountId and career_modules_bank then
    local accountBalance = career_modules_bank.getAccountBalance(accountId)
    for currency, info in pairs(price) do
      if currency == "money" then
        if not info.canBeNegative and accountBalance < info.amount then
          return false
        end
      end
    end
    return true
  end
  
  for currency, info in pairs(price) do
    if not info.canBeNegative and career_modules_playerAttributes.getAttributeValue(currency) < info.amount then
      return false
    end
  end
  return true
end

local function pay(price, reason, accountId)
  if not canPay(price, accountId) then return false end
  if career_modules_cheats and career_modules_cheats.isCheatsMode() then
    return true
  end
  
  if accountId and career_modules_bank then
    return career_modules_bank.payFromAccount(price, accountId)
  end
  
  local change = {}
  for currency, info in pairs(price) do
    change[currency] = -info.amount
  end
  career_modules_playerAttributes.addAttributes(change, reason)
  return true
end

local function reward(price, reason, fullReward, accountId)
  if accountId and career_modules_bank then
    return career_modules_bank.rewardToAccount(price, accountId)
  end
  
  local change = {}
  for currency, info in pairs(price) do
    change[currency] = info.amount
  end
  career_modules_playerAttributes.addAttributes(change, reason, fullReward)
  return true
end

M.canPay = canPay
M.pay = pay
M.reward = reward

return M