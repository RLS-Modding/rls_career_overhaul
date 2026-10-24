-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/payment.lua (BeamNG 0.40).
-- Career payments: canPay, pay, reward and the payout composition used by jobs and shifts.
-- Keeps the stock layout on purpose so it still diffs against stock.

local M = {}

local sponsor = require("overhaul/lib/ledger/sponsors")
local wageHolders = require("overhaul/career/economy/payment/wageHolders")
local manifests = require("overhaul/lib/platform/manifests")
local lifecycle = require("overhaul/lib/lifecycle/host")

-- Payment owns discovered service registrations for this extension instance.
local SERVICE_LOG_TAG = "overhaul_sponsored_services"

local function validateServicePolicy(data)
  if not manifests.isNonEmptyString(data.definition) or
    not data.definition:match("^[%w_][%w_/%.%-]*$") or data.definition:find("..", 1, true) or
    data.definition:sub(-4) == ".lua" then
    return nil, "definition must be a module path (require name, no .lua)"
  end
  if data.order <= -math.huge or data.order >= math.huge then return nil, "order must be finite" end
  return {id = data.id, order = data.order, definition = data.definition}
end

local serviceEpoch, serviceDisposers, servicesUnloaded = nil, {}, false
local servicePolicies = {}

local function clearServicePolicies()
  for _, dispose in ipairs(serviceDisposers) do dispose() end
  serviceDisposers = {}
end

-- Rescans only when the career, map or profile epoch has moved.
function servicePolicies.refresh()
  if servicesUnloaded then return end
  local current = lifecycle.epochs()
  if serviceEpoch and current.career == serviceEpoch.career and current.map == serviceEpoch.map and
    current.profile == serviceEpoch.profile then return end
  clearServicePolicies()
  local entries = manifests.scan({dir = "/gameplay/overhaul/sponsoredServices/", tag = SERVICE_LOG_TAG, validate = validateServicePolicy})
  for _, entry in ipairs(entries) do
    local ok, definition = pcall(require, entry.definition)
    if ok and type(definition) == "table" then
      local service = {matches = definition.matches, onCovered = definition.onCovered, order = entry.order}
      local registered, dispose = pcall(sponsor.registerService, entry, service)
      if registered then serviceDisposers[#serviceDisposers + 1] = dispose
      else ok, definition = false, dispose end
    else
      ok, definition = false, ok and "definition must return a service table" or definition
    end
    if not ok then
      log("W", SERVICE_LOG_TAG, "Ignoring service " .. entry.id .. ": " .. tostring(definition))
    end
  end
  serviceEpoch = current
end

function servicePolicies.dispose()
  servicesUnloaded = true
  clearServicePolicies()
end


local function canPay(price, accountId)
  if accountId and overhaul_career_economy_bank then
    local accountBalance = overhaul_career_economy_bank.getAccountBalance(accountId)
    for currency, info in pairs(price) do
      if currency == "money" then
        if not info.canBeNegative and info.amount > 0 and accountBalance < info.amount then
          return false
        end
      end
    end
    return true
  end

  if overhaul_career_economy_cheats and overhaul_career_economy_cheats.isCheatsMode() then
    return true
  end

  for currency, info in pairs(price) do
    if not info.canBeNegative and info.amount > 0 and overhaul_career_economy_playerAttributes.getAttributeValue(currency) < info.amount then
      return false
    end
  end
  return true
end

local function pay(price, reason, accountId, onRecorded)
  servicePolicies.refresh()
  if sponsor.tryCover(price, reason, accountId) then return true end

  if not canPay(price, accountId) then return false end

  if accountId and overhaul_career_economy_bank then
    reason = reason or {}
    return overhaul_career_economy_bank.payFromAccount(price, accountId, reason.label, reason.description,
      reason)
  end

  local change = {}
  for currency, info in pairs(price) do
    change[currency] = -info.amount
  end
  overhaul_career_economy_playerAttributes.addAttributes(change, reason, nil, onRecorded)
  return true
end

local function reward(price, reason, fullReward, accountId)
  if accountId and overhaul_career_economy_bank then
    reason = reason or {}
    return overhaul_career_economy_bank.rewardToAccount(price, accountId, reason.label, reason.description,
      reason)
  end
  
  local change = {}
  for currency, info in pairs(price) do
    change[currency] = info.amount
  end
  overhaul_career_economy_playerAttributes.addAttributes(change, reason, fullReward)
  return true
end

-- Earnings composition only: callers own amount math, scaling, completion guards and
-- split-leg ordering. One payout delegates once to the existing reward primitive (or
-- the selected owner's wage holder); it never posts another Ledger operation.
--
-- spec: amount (finite; nonnegative unless opted in below; omit for XP/reputation-only legs), optional reason
-- preserves every caller-supplied field, including canBeNegative=false; explicit
-- source/category/label/tags/description/breakdown
-- override its corresponding fields. xp is a finite signed attribute->amount map or {key, amount};
-- orgId + rep adds orgId.."Reputation". fullReward preserves nil/false/true exactly.
-- destination defaults to "wallet"; {kind="account", accountId=id} preserves reward's
-- money-only behavior and its wallet fallback if the bank is absent. Account payouts
-- refuse any xp or rep field; split these into an explicit wallet payout;
-- {kind="heldWages", holder=handle} delegates the whole composition to its holder.
-- The wage owner gets handle, dispose from registerWageHolder(owner, {hold=fn}) and
-- passes handle to earnings callers in their shift/job context. Callers return that
-- opaque handle here; they do not query the wage owner or register a second holder.
-- An account/wallet split is two explicit payouts, in the owner's existing order.
--
-- Explicit amount=0 still makes the legacy zero-money posting; omitted money does not.
-- allowNetDebit=true permits negative net earnings without clamping or splitting:
-- wallet money, XP and reputation remain one reward call. Account destinations still
-- refuse negative amounts, including their absent-bank wallet fallback.
-- allowEmpty=true lets a spec with no money, XP or reputation make one empty reward call.
-- Shared skill XP needs it: difficulty scaling can remove every XP entry and the log row
-- plus the attribute-changed hook for that empty change are part of today's behaviour.
-- Result: true means the primitive returned successfully, or the holder accepted it.
-- false, diagnostic means invalid input/stale holder or backend refusal. Invalid input
-- makes no call. Wallet success follows reward: an addAttributes return is ignored.
-- Exceptions propagate unchanged; they can happen AFTER a partial mutation. Neither
-- false nor a thrown error permits automatic retry or clearing completion state. There
-- is no rollback/dedupe: duplicate or late calls execute again like reward today.
local function finite(amount)
  return type(amount) == "number" and amount == amount and amount > -math.huge and amount < math.huge
end

local function payout(spec)
  if type(spec) ~= "table" or (spec.amount ~= nil and (not finite(spec.amount) or
    (spec.amount < 0 and spec.allowNetDebit ~= true))) then
    return false, "payout needs a finite nonnegative amount"
  end

  local price = {}
  if spec.amount ~= nil then price.money = {amount = spec.amount} end
  local function addXp(key, amount)
    if type(key) ~= "string" or key == "" or key == "money" or not finite(amount) then
      return false
    end
    price[key] = {amount = amount}
    return true
  end
  if spec.xp ~= nil then
    if type(spec.xp) ~= "table" then return false, "invalid payout XP" end
    if spec.xp.key ~= nil then
      if not addXp(spec.xp.key, spec.xp.amount) then return false, "invalid payout XP" end
    else
      for key, amount in pairs(spec.xp) do
        if not addXp(key, amount) then return false, "invalid payout XP" end
      end
    end
  end
  if spec.rep ~= nil then
    if type(spec.orgId) ~= "string" or spec.orgId == "" or not finite(spec.rep) then
      return false, "payout reputation needs an organization and finite amount"
    end
    local key = spec.orgId .. "Reputation"
    if price[key] then return false, "duplicate payout reputation attribute" end
    price[key] = {amount = spec.rep}
  end
  if next(price) == nil and spec.allowEmpty ~= true then return false, "payout needs money, XP or reputation" end

  local destination = spec.destination
  local kind = destination == nil and "wallet" or destination
  if type(destination) == "table" then kind = destination.kind end
  if kind ~= "wallet" and kind ~= "account" and kind ~= "heldWages" then
    return false, "unknown payout destination"
  end
  if kind ~= "wallet" and type(destination) ~= "table" then return false, "payout destination needs fields" end
  if kind == "account" and (destination.accountId == nil or destination.accountId == "" or
    (type(destination.accountId) ~= "string" and type(destination.accountId) ~= "number")) then
    return false, "payout account needs accountId"
  end
  if kind == "account" and spec.amount ~= nil and spec.amount < 0 then
    return false, "account payout cannot debit net earnings; use a wallet payout"
  end
  if kind == "account" and (spec.xp ~= nil or spec.rep ~= nil) then
    return false, "account payout carries money only; split XP into a wallet payout"
  end
  if spec.reason ~= nil and type(spec.reason) ~= "table" then return false, "payout reason must be a table" end
  local reason = {}
  for key, value in pairs(spec.reason or {}) do reason[key] = value end
  for _, key in ipairs({"source", "category", "label", "tags", "description", "breakdown"}) do
    if spec[key] ~= nil then reason[key] = spec[key] end
  end
  if reason.tags ~= nil and type(reason.tags) ~= "table" then return false, "payout tags must be a table" end
  if kind == "heldWages" then return wageHolders.hold(destination.holder, price, reason, spec.fullReward) end
  local accepted, problem = reward(price, reason, spec.fullReward, kind == "account" and destination.accountId or nil)
  if accepted == true then return true end
  return false, problem or "payout destination refused"
end

M.canPay = canPay
M.pay = pay
M.reward = reward
M.payout = payout
M.registerWageHolder = wageHolders.register
M.onExtensionLoaded = servicePolicies.refresh
M.onExtensionUnloaded = servicePolicies.dispose

return M
