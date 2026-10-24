-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Insurance history: the player's saved claims, tickets and policy events, newest first for the UI.
-- Fork of stock lua/ge/extensions/career/modules/insurance/history.lua (BeamNG 0.40); read state, then the public API.
local M = {}

-- player saved data
local plHistory = {} -- claims, tickets ...

local function addToPlHistory(data)
  table.insert(plHistory, {
    type = data.type,
    title = data.title,
    effects = data.effects,
    concernedInsuranceName = data.concernedInsuranceName,
    overrideText = data.overrideText,
    other = data.other,
    time = os.time(),
  })
end

local function sortByTimeReverse(a,b) return a.time > b.time end
local function buildPlHistory()
  local list = deepcopy(plHistory)
  table.sort(list, sortByTimeReverse)

  for _, event in pairs(list) do
    event.date = os.date("%c", event.time)
  end
  return list
end

local function getHistoryTotalDetails(type)
  local details = {
    totalMoney = 0,
    totalCount = 0,
  }
  for _, historyEntry in ipairs(plHistory) do
    if historyEntry.type == type then
      -- effects contains {type = "money", label = "Money", changedBy = -amount, newValue = ...}
      for _, effect in ipairs(historyEntry.effects or {}) do
        if effect.type == "money" and effect.changedBy then
          -- changedBy is negative (money spent), so we add absolute value
          details.totalMoney = details.totalMoney + math.abs(effect.changedBy)
          details.totalCount = details.totalCount + 1
        end
      end
    end
  end
  return details
end

local function getPlHistory()
  return plHistory
end

local function setPlHistory(history)
  plHistory = history or {}
end

local function initPlHistory()
  plHistory = {}
end

local function getTotalInsuranceRepairDeductiblesPaid()
  local total = 0
  for _, historyEntry in ipairs(plHistory) do
    if historyEntry.type == "insuranceRepairClaim" and historyEntry.other and historyEntry.other.deductible then
      total = total + historyEntry.other.deductible
    end
  end
  return total
end

local function getDamageCostCoveredByInsurance()
  local totalDamageCost = 0
  for _, historyEntry in ipairs(plHistory) do
    if historyEntry.type == "insuranceRepairClaim" and historyEntry.other and historyEntry.other.vehDamagePrice then
      totalDamageCost = totalDamageCost + historyEntry.other.vehDamagePrice
    end
  end
  return totalDamageCost
end

local function getInsuranceClaimsCount()
  return getHistoryTotalDetails("insuranceRepairClaim").totalCount
end

local function getNonInsuranceRepairsCount()
  return getHistoryTotalDetails("privateRepair").totalCount
end

local function getTotalPremiumPaid()
  local totalRenewals =getHistoryTotalDetails("insuranceRenewed").totalMoney
  local totalInsuranceChanges = getHistoryTotalDetails("insuranceChanged").totalMoney
  return totalRenewals + totalInsuranceChanges
end

local function getTotalPrivateRepairsPaid()
  return getHistoryTotalDetails("privateRepair").totalMoney
end

M.addToPlHistory = addToPlHistory
M.buildPlHistory = buildPlHistory
M.getPlHistory = getPlHistory
M.setPlHistory = setPlHistory
M.initPlHistory = initPlHistory

-- get history details
M.getInsuranceClaimsCount = getInsuranceClaimsCount
M.getNonInsuranceRepairsCount = getNonInsuranceRepairsCount
M.getTotalPremiumPaid = getTotalPremiumPaid
M.getTotalInsuranceRepairDeductiblesPaid = getTotalInsuranceRepairDeductiblesPaid
M.getTotalPrivateRepairsPaid = getTotalPrivateRepairsPaid
M.getDamageCostCoveredByInsurance = getDamageCostCoveredByInsurance
return M