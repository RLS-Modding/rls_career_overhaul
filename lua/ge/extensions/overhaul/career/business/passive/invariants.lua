-- Balance checks for the passive business archetypes, facility prices, the balance refund and production timing.
-- The owner module runs them through runInvariantTests, which returns a result table.
local M = {}

local function expect(failures, condition, label)
  if not condition then failures[#failures + 1] = label end
end

-- Returns the base profit per hour, which the facility checks use.
local function checkArchetype(failures, archetypeId, archetype)
  if archetype.supplyType == false then return 0 end
  local cycle = tonumber(archetype.cycleSeconds) or 0
  local cost = tonumber(archetype.unitCost) or 0
  local revenue = tonumber(archetype.unitRevenue) or 0
  local wholesaleCost = tonumber(archetype.wholesaleUnitCost) or 0
  local baseProfitPerHour = cycle > 0 and ((revenue - cost) * 3600 / cycle) or 0
  local wholesaleProfitPerHour = cycle > 0 and ((revenue - wholesaleCost) * 3600 / cycle) or 0
  local wholesaleGainPerHour = wholesaleProfitPerHour - baseProfitPerHour
  local wholesalePaybackHours = wholesaleGainPerHour > 0
    and ((tonumber(archetype.wholesaleUpgradeCost) or 0) / wholesaleGainPerHour) or 0
  local storageTotal = 0
  for _, upgradeCost in ipairs(archetype.storageUpgradeCosts or {}) do storageTotal = storageTotal + (tonumber(upgradeCost) or 0) end
  local storageCostHours = baseProfitPerHour > 0 and storageTotal / baseProfitPerHour or 0

  expect(failures, archetype.supplySlots == 128, archetypeId .. " supply pallet must use 128 slots")
  expect(failures, cycle >= 300 and cycle <= 900, archetypeId .. " cycle is outside the five-to-fifteen-minute range")
  expect(failures, cost > 0 and revenue > cost, archetypeId .. " base unit economics are invalid")
  expect(failures, wholesaleCost > 0 and wholesaleCost < cost, archetypeId .. " wholesale price must discount supplies")
  expect(failures, baseProfitPerHour >= 5000 and baseProfitPerHour <= 30000,
    archetypeId .. " base hourly profit is outside the balance range")
  expect(failures, wholesaleProfitPerHour > baseProfitPerHour and wholesaleProfitPerHour <= 40000,
    archetypeId .. " wholesale hourly profit is outside the balance range")
  expect(failures, wholesalePaybackHours >= 6 and wholesalePaybackHours <= 10,
    archetypeId .. " wholesale upgrade payback is outside the balance range")
  expect(failures, storageCostHours >= 4 and storageCostHours <= 6,
    archetypeId .. " total storage upgrade cost is outside the balance range")
  expect(failures, type(archetype.storageCapacities) == "table" and #archetype.storageCapacities == 5,
    archetypeId .. " must define five storage levels")
  expect(failures, type(archetype.storageUpgradeCosts) == "table" and #archetype.storageUpgradeCosts == 4,
    archetypeId .. " must define four storage upgrade prices")
  for index = 2, #(archetype.storageCapacities or {}) do
    expect(failures, archetype.storageCapacities[index] > archetype.storageCapacities[index - 1],
      archetypeId .. " storage capacities must increase")
  end
  for index = 2, #(archetype.storageUpgradeCosts or {}) do
    expect(failures, archetype.storageUpgradeCosts[index] > archetype.storageUpgradeCosts[index - 1],
      archetypeId .. " storage upgrade prices must increase")
  end
  return baseProfitPerHour
end

-- Checks each authored archetype and returns the count.
local function checkArchetypes(failures, archetypes)
  local archetypeCount = 0
  for archetypeId, archetype in pairs(archetypes) do
    archetypeCount = archetypeCount + 1
    checkArchetype(failures, archetypeId, archetype)
  end
  return archetypeCount
end

-- Validate the current level's references without fixing its count, names or price tiers.
local function checkFacilities(failures, facilityData, archetypes, locationAvailable)
  local businessCount, earlyGameCount, seen = 0, 0, {}
  for _, facility in ipairs(facilityData.passiveBusinesses or {}) do
    businessCount = businessCount + 1
    local id = tostring(facility.id)
    local price = tonumber(facility.price) or 0
    expect(failures, not seen[id], id .. " duplicates a business id")
    seen[id] = true
    expect(failures, archetypes[facility.archetypeId] ~= nil, id .. " references a missing archetype")
    expect(failures, price > 0, id .. " requires a positive purchase price")
    local archetype = archetypes[facility.archetypeId]
    for _, role in ipairs(archetype and archetype.supplyType == false and {} or {"supplier", "receiving"}) do
      local endpoint, parking = facility[role .. "FacilityId"], facility[role .. "ParkingSpotName"]
      expect(failures, type(endpoint) == "string" and type(parking) == "string", id .. " requires " .. role .. " endpoint data")
      if locationAvailable and endpoint and parking then
        expect(failures, locationAvailable(endpoint, parking), id .. " references an unavailable " .. role .. " parking spot")
      end
    end
    if price <= 110000 then earlyGameCount = earlyGameCount + 1 end
  end
  return businessCount, earlyGameCount
end

-- The refund must return every repriced owned upgrade exactly once.
local function checkBalanceRefund(failures, inputs)
  local archetypes = inputs.archetypes()
  local legacy = inputs.legacyBalance.miniMart
  local current = archetypes.miniMart
  local expectedRefund = 0
  for index = 1, 4 do
    expectedRefund = expectedRefund + inputs.indexed(legacy.storageUpgradeCosts[index])
      - inputs.indexed(current.storageUpgradeCosts[index])
  end
  expectedRefund = expectedRefund + inputs.indexed(legacy.wholesaleUpgradeCost) - inputs.indexed(current.wholesaleUpgradeCost)
  local refundState = {archetypeId = "miniMart", storageLevel = 5, wholesaleOwned = true}
  expect(failures, inputs.balanceRefundForState(refundState) == expectedRefund,
    "balance refund must return every repriced owned upgrade exactly once")
end

-- Production timing: partial cycles, one cycle and the full starting stock.
local function checkProductionTiming(failures, inputs)
  local miniMart = inputs.archetypes().miniMart
  if not miniMart then return end
  local advance = inputs.advanceState
  local startingStock = miniMart.storageCapacities[1]
  local simulation = {stock = startingStock, cycleProgress = 0, uncollectedEarnings = 0}
  expect(failures, advance(simulation, miniMart, miniMart.cycleSeconds - 1, miniMart.unitRevenue) == 0
    and simulation.stock == startingStock and simulation.cycleProgress == miniMart.cycleSeconds - 1,
    "partial cycle timing mismatch")
  expect(failures, advance(simulation, miniMart, 1, miniMart.unitRevenue) == 1
    and simulation.stock == startingStock - 1 and simulation.uncollectedEarnings == miniMart.unitRevenue,
    "single cycle timing mismatch")
  expect(failures, advance(simulation, miniMart, (startingStock - 1) * miniMart.cycleSeconds, miniMart.unitRevenue) == startingStock - 1
    and simulation.stock == 0 and simulation.cycleProgress == 0
    and simulation.uncollectedEarnings == startingStock * miniMart.unitRevenue,
    "full starting stock production mismatch")
end

-- balanceRefundForState, advanceState.
function M.new(inputs)
  return function()
    inputs.loadArchetypes()
    local failures = {}
    local archetypes = inputs.archetypes()
    local archetypeCount = checkArchetypes(failures, archetypes)
    local facilityData = inputs.facilityData()
    local businessCount, earlyGameCount = checkFacilities(failures, facilityData, archetypes, inputs.locationAvailable)
    checkBalanceRefund(failures, inputs)
    checkProductionTiming(failures, inputs)
    return {
      success = #failures == 0,
      failures = failures,
      archetypeCount = archetypeCount,
      businessCount = businessCount,
      earlyGameCount = earlyGameCount
    }
  end
end

return M
