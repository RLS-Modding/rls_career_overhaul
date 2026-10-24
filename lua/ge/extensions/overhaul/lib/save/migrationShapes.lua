-- Shapes shared by the 0.39 disk migration (career/saveMigration.lua) and the in-memory import.
-- Callers retain orchestration: disk migration reports failures while import commits a staged copy on success.

local M = {}

-- Recursive value equality, in both directions, so a missing key counts as a difference.
function M.sameData(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for key, value in pairs(a) do
    if not M.sameData(value, b[key]) then return false end
  end
  for key in pairs(b) do
    if a[key] == nil then return false end
  end
  return true
end

-- Legacy rows may use numeric ids, string ids or arrays; preserve their original matching order.
function M.lookupOldInvVeh(oldInvVehs, inventoryId)
  local row = oldInvVehs[inventoryId]
  if type(row) == "table" then return row end
  row = oldInvVehs[tostring(inventoryId)]
  if type(row) == "table" then return row end
  for _, candidate in pairs(oldInvVehs) do
    if type(candidate) == "table" and (tonumber(candidate.id) or candidate.id) == inventoryId then
      return candidate
    end
  end
  return nil
end

-- Fills the fields insurance load expects on an invVehs row, keeping any salvageable values.
function M.ensureInvVehShape(row, inventoryId, vehicle)
  row = type(row) == "table" and row or {}
  row.id = inventoryId
  if row.insuranceId == nil then
    row.insuranceId = -1
  else
    row.insuranceId = tonumber(row.insuranceId) or -1
  end
  if type(row.name) ~= "string" or row.name == "" then
    row.name = (vehicle and vehicle.niceName) or ("Vehicle " .. tostring(inventoryId))
  end
  if type(row.initialValue) ~= "number" then
    row.initialValue = (tonumber(vehicle and vehicle.configBaseValue) or 0) / 3
  end
  if type(row.insuranceData) ~= "table" then
    row.insuranceData = {}
  end
  if type(row.insuranceData.coverageOptionsData) ~= "table" then
    row.insuranceData.coverageOptionsData = {}
  end
  if type(row.insuranceData.coverageOptionsData.currentCoverageOptions) ~= "table" then
    row.insuranceData.coverageOptionsData.currentCoverageOptions = {}
  end
  if row.insuranceData.coverageOptionsData.nextInsuranceEditTimer == nil then
    row.insuranceData.coverageOptionsData.nextInsuranceEditTimer = 0
  end
  if type(row.requiredInsuranceClass) ~= "table" then
    row.requiredInsuranceClass = {id = "standard"}
  elseif row.requiredInsuranceClass.id == nil then
    row.requiredInsuranceClass.id = "standard"
  end
  return row
end

-- The rebuilt insurance.json: profile-level fields from the old file, with fresh invVehs.
function M.insuranceData(oldData, newInvVehs)
  return {
    plDriverScore = tonumber(oldData.plDriverScore) or 65,
    lastDriverScoreKmIncrease = tonumber(oldData.lastDriverScoreKmIncrease) or 0,
    totalDrivenDistance = tonumber(oldData.totalDrivenDistance) or 0,
    plInsurancesData = type(oldData.plInsurancesData) == "table" and oldData.plInsurancesData or {},
    invVehs = newInvVehs,
    plHistory = oldData.plHistory,
  }
end

-- Counts the parts the 0.40 rename changed, and the parts it moved into the loose inventory.
function M.countPartChanges(inventory, beforeInventory, summary)
  for id, part in pairs(inventory) do
    local before = beforeInventory[id]
    if not M.sameData(part, before) then summary.partsMigrated = summary.partsMigrated + 1 end
    if type(part) == "table" and tonumber(part.location) == 0
      and (not before or tonumber(before.location) ~= 0) then
      summary.itemsMovedToInventory = summary.itemsMovedToInventory + 1
    end
  end
end

return M
