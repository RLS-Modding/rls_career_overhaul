-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- Policies and lifecycle operations for issued and company vehicles.
-- Policy reads stay separate from mutation so inventories and loan owners retain settlement authority.
local M = {}

-- Keep loan policies separate; the saved issued record retains only its existing loan type.
M.POLICIES = {
  company = {loanType = "company", issuer = "loaners", billing = "none", returnPath = "loaners",
    damagedReturn = "reputation, police exempt", notifiesEmployment = true},
  work = {loanType = "work", issuer = "loaners", billing = "none", returnPath = "loaners",
    damagedReturn = "reputation, police exempt"},
  rental = {loanType = "rental", issuer = "loaners", billing = "hourly, settled on return", returnPath = "loaners",
    damagedReturn = "half reputation", notifiesEmployment = "damage only"},
  mining = {loanType = "work", issuer = "miningHaul", billing = "none", returnPath = "miningHaul",
    damagedReturn = "none"},
}

-- Policy projection reads issued records without mutating inventory ownership.
function M.forVehicle(vehInfo, issuer)
  if not vehInfo or not vehInfo.loanType then return nil end
  local loanTypePolicy = M.POLICIES[vehInfo.loanType]
  local issuerPolicy = issuer and M.POLICIES[issuer]
  if issuerPolicy and issuerPolicy.loanType ~= vehInfo.loanType then issuerPolicy = nil end
  return {
    loanType = vehInfo.loanType,
    organization = vehInfo.owningOrganization,
    brokerRentalId = vehInfo.brokerRentalId,
    issuer = issuerPolicy and issuer or nil,
    loanTypePolicy = loanTypePolicy,
    policy = issuerPolicy or loanTypePolicy,
    isCompany = loanTypePolicy == M.POLICIES.company,
    isWork = loanTypePolicy == M.POLICIES.work,
    isRental = loanTypePolicy == M.POLICIES.rental,
    isDelivery = vehInfo.loanType == 'delivery',
  }
end

-- Inventory lookup adds the inventory and scene IDs without changing the record's policy.
function M.get(inventory, inventoryId, issuer)
  local vehicles = inventory and inventory.getVehicles and inventory.getVehicles()
  local record = M.forVehicle(vehicles and vehicles[inventoryId], issuer)
  if not record then return nil end
  record.inventoryId = inventoryId
  record.vehId = inventory.getVehicleIdFromInventoryId and inventory.getVehicleIdFromInventoryId(inventoryId) or nil
  return record
end

-- Issues a company vehicle: marks the offer for the loaner extension's next spawn at the facility.
function M.issueCompany(loaners, offer, facilityId, idPrefix)
  return loaners.markCompanyOfferForSpawning(offer, facilityId, idPrefix)
end

-- Spawns every marked offer (company and work loaners), then onReady; without the loaner extension, onReady at once.
function M.spawnMarked(loaners, onReady)
  if loaners and loaners.spawnAllOffers then
    loaners.spawnAllOffers(onReady)
  else
    onReady()
  end
end

-- Issues an hourly rental: the offer becomes the only marked offer and is spawned; onSpawned runs when that ends.
function M.issueRental(loaners, offer, onSpawned)
  loaners.unmarkAllForSpawning()
  loaners.setMarkedForSpawning(offer, true)
  return loaners.spawnAllOffers(onSpawned)
end

-- Step out before reading the current issued ids so callbacks see the original vehicle state.
function M.returnCompany(loaners, ids, ...)
  loaners.stepOutIfInCompanyVehicle()
  if type(ids) == "function" then ids = ids() end
  return loaners.returnVehicles(ids, ...)
end

-- Returns one loaner (rental, work or company) through the loaner returns, rental settlement included.
function M.returnLoaner(loaners, inventoryId, ...)
  return loaners.returnVehicle(inventoryId, ...)
end

-- Inventory adoption keeps its existing order and refusal path while the loan owner retains settlement.
function M.adopt(inventory, vehId, loanType, organizationId)
  if not inventory or not inventory.addVehicle then return nil end
  local inventoryId = inventory.addVehicle(vehId, nil, { owned = false })
  local vehicles = inventory.getVehicles and inventory.getVehicles()
  local vehInfo = vehicles and inventoryId and vehicles[inventoryId]
  if vehInfo then
    vehInfo.owningOrganization = organizationId
    vehInfo.loanType = loanType
  end
  return inventoryId
end

-- Capture conditions before inventory removal; returning an adopted vehicle does not settle a loan.
function M.returnAdopted(inventory, inventoryId)
  if not (inventoryId and inventory and inventory.removeVehicle) then return false end
  if inventory.updatePartConditions and inventory.getVehicleIdFromInventoryId and inventory.getVehicleIdFromInventoryId(inventoryId) then
    inventory.updatePartConditions(nil, inventoryId, function()
      inventory.removeVehicle(inventoryId)
    end)
  else
    inventory.removeVehicle(inventoryId)
  end
  return true
end

return M
