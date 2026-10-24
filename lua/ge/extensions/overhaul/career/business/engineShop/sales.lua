-- Engine-shop landed costs, sale pricing and sales cycles.
-- Each construction captures one shop so reloads cannot reuse earlier state or callbacks.
local part = {}

-- Each construction keeps its callbacks bound to that owner load.
function part.new(inputs)
  local FRESH_VALUE_MARKET_MULTIPLIER = inputs.config.FRESH_VALUE_MARKET_MULTIPLIER
  local LANDED_COST_FLOOR_MULTIPLIER = inputs.config.LANDED_COST_FLOOR_MULTIPLIER
  local ENGINE_SALE_MIN_SECONDS = inputs.config.ENGINE_SALE_MIN_SECONDS
  local ENGINE_SALE_MAX_SECONDS = inputs.config.ENGINE_SALE_MAX_SECONDS

  -- Shared helpers belong to this owner load and are read when an operation runs.
  local host = inputs.host

  -- Cost of the latest twenty attempts for this engine, spread over the successful ones.
  local function landedCost(blueprint, lines)
    local total, successes = 0, 0
    local rows = {}
    for _, line in ipairs(lines or {}) do
      for _, attempt in ipairs(line.attempts or {}) do
        if tostring(attempt.blueprintId or "") == tostring(blueprint.id) then
          rows[#rows + 1] = attempt
        end
      end
    end
    table.sort(rows, function(a, b) return (a.at or 0) > (b.at or 0) end)
    for index = 1, math.min(20, #rows) do
      total = total + (rows[index].cost or 0)
      if rows[index].success then successes = successes + 1 end
    end
    return successes > 0 and total / successes or (blueprint.freshValue or 1)
  end

  local function supportedMarketPrice(blueprint, cost, state)
    local freshValue = math.max(1, tonumber(blueprint and blueprint.freshValue) or 1)
    cost = math.max(1, tonumber(cost) or freshValue)
    local marketAnchor = freshValue * FRESH_VALUE_MARKET_MULTIPLIER
    local costFloor = cost * LANDED_COST_FLOOR_MULTIPLIER
    local brandPremium = inputs.config.BRAND_PRICE_BONUS_MAX * math.min(1, math.max(0, tonumber(state and state.brandPopularity) or 0) / 100)
    local awarenessPremium = inputs.config.PRODUCT_PRICE_BONUS_MAX * math.min(1, math.max(0, tonumber(blueprint and blueprint.awareness) or 0) / 100)
    return math.max(marketAnchor, costFloor) * (1 + brandPremium + awarenessPremium)
  end

  local function salePriceLimit(blueprint, cost, state)
    local supportedPrice = math.max(1, supportedMarketPrice(blueprint, cost, state))
    local brand = math.max(0, math.min(100, tonumber(state and state.brandPopularity) or 0))
    local awareness = math.max(0, math.min(100, tonumber(blueprint and blueprint.awareness) or 0))
    local maturity = (brand + awareness) / 200
    local supportedSeconds = ENGINE_SALE_MAX_SECONDS - (ENGINE_SALE_MAX_SECONDS - ENGINE_SALE_MIN_SECONDS) * maturity
    -- A premium can only use the timer headroom left before the fifteen-minute limit.
    local maxRatio = (ENGINE_SALE_MAX_SECONDS / supportedSeconds + 1) / 2
    return math.max(1, math.floor(supportedPrice * maxRatio + 0.5)), supportedPrice, supportedSeconds
  end

  local function normalizeBlueprintPrice(blueprint, state)
    local limit, supportedPrice = salePriceLimit(blueprint, landedCost(blueprint, state.lines), state)
    local price = tonumber(blueprint.price) or supportedPrice
    if price ~= price or price == math.huge or price == -math.huge then price = supportedPrice end
    price = math.max(1, math.min(limit, math.floor(price)))
    local changed = blueprint.price ~= price
    blueprint.price = price
    return changed
  end

  local function saleCycleSeconds(blueprint, cost, state)
    local limit, supportedPrice, supportedSeconds = salePriceLimit(blueprint, cost, state)
    local priceRatio = math.max(0.01, math.min(tonumber(blueprint and blueprint.price) or supportedPrice, limit) / supportedPrice)
    local multiplier
    if priceRatio <= 1 then
      multiplier = math.max(0.5, priceRatio)
    else
      multiplier = 1 + (priceRatio - 1) * 2
    end
    local seconds = math.max(ENGINE_SALE_MIN_SECONDS, math.min(ENGINE_SALE_MAX_SECONDS, supportedSeconds * multiplier))
    return math.floor(seconds + 0.5), supportedPrice
  end

  local function destroyWarehousePackage(id, package)
    if not package or package.ownerType ~= "business" or tostring(package.businessId) ~= tostring(id) or package.warehouseStock ~= true then return false end
    local partIds = overhaul_career_parts_engines_enginePackages.getPartIdsFromPackageTree(package.tree)
    local removed = overhaul_career_parts_engines_enginePackages.removeBusinessPackage(package.id)
    if not removed then return false end
    for _, partId in ipairs(partIds) do overhaul_career_business_partInventory.removePart(partId, tostring(id)) end
    return true
  end

  local function resetSalesCycle(state)
    state.salesCurrentBlueprintId = nil
    state.salesCycleProgressSeconds = 0
    state.salesCycleDurationSeconds = nil
    state.salesCycleMigrationRatio = nil
  end

  local function saleCandidates(id, state)
    local rows = {}
    for _, blueprint in pairs(state.blueprints or {}) do
      if blueprint.listed and #host.warehousePackages(id, blueprint.id) > 0 then rows[#rows + 1] = blueprint end
    end
    table.sort(rows, function(a, b)
      local aId, bId = tonumber(a.id), tonumber(b.id)
      if aId and bId then return aId < bId end
      return tostring(a.id) < tostring(b.id)
    end)
    return rows
  end

  -- Keeps the current listing's countdown while it still has stock; otherwise picks the next listing after the cursor.
  local function ensureSalesCycle(id, state)
    local current = state.salesCurrentBlueprintId and state.blueprints[tostring(state.salesCurrentBlueprintId)]
    if current and current.listed and #host.warehousePackages(id, current.id) > 0 then
      if not state.salesCycleDurationSeconds or state.salesCycleDurationSeconds <= 0 then
        state.salesCycleDurationSeconds = saleCycleSeconds(current, landedCost(current, state.lines), state)
        if state.salesCycleMigrationRatio then
          state.salesCycleProgressSeconds = state.salesCycleDurationSeconds * state.salesCycleMigrationRatio
          state.salesCycleMigrationRatio = nil
        end
      end
      state.salesCycleProgressSeconds = math.min(state.salesCycleProgressSeconds or 0, state.salesCycleDurationSeconds)
      return current
    end

    resetSalesCycle(state)
    local candidates = saleCandidates(id, state)
    if #candidates == 0 then return nil end
    local selected = candidates[1]
    if state.salesCursorBlueprintId then
      for index, candidate in ipairs(candidates) do
        if tostring(candidate.id) == tostring(state.salesCursorBlueprintId) then
          selected = candidates[index % #candidates + 1]
          break
        end
      end
    end
    state.salesCurrentBlueprintId = tostring(selected.id)
    state.salesCycleDurationSeconds = saleCycleSeconds(selected, landedCost(selected, state.lines), state)
    return selected
  end

  local function completeCurrentSale(id, state, blueprint)
    local available = host.warehousePackages(id, blueprint.id)
    local package = available[1]
    if not package then
      resetSalesCycle(state)
      return false
    end
    -- no account to pay into: keep the engine and the finished cycle until there is one
    if not host.accountFor(id) then return false end
    if not destroyWarehousePackage(id, package) then
      resetSalesCycle(state)
      return false
    end
    local cost = landedCost(blueprint, state.lines)
    local duration = state.salesCycleDurationSeconds or saleCycleSeconds(blueprint, cost, state)
    local supportedPrice = supportedMarketPrice(blueprint, cost, state)
    local price = math.max(1, math.min(salePriceLimit(blueprint, cost, state), math.floor(tonumber(blueprint.price) or supportedPrice)))
    if not host.reward(id, price, blueprint.name .. " sale", "One physical engine sold from the timed sales queue") then
      log("E", "engineShop", "Engine sale payment failed for business " .. tostring(id) .. ": " .. tostring(price))
    end
    state.brandPopularity = math.min(100, state.brandPopularity + 1)
    blueprint.awareness = math.max(0, (tonumber(blueprint.awareness) or 0) - 1)
    local _, day, minute = host.nowWorldMinutes()
    state.salesHistory[#state.salesHistory + 1] = {day = day, minuteOfDay = minute, blueprintId = blueprint.id,
      name = blueprint.name, sold = 1, price = price, landedCost = cost,
      supportedPrice = math.floor(supportedPrice + 0.5), saleCycleSeconds = duration}
    while #state.salesHistory > 120 do table.remove(state.salesHistory, 1) end
    state.salesCursorBlueprintId = tostring(blueprint.id)
    resetSalesCycle(state)
    return true
  end

  local function advanceSales(id, state, elapsedSeconds)
    local remainingElapsed = math.max(0, tonumber(elapsedSeconds) or 0)
    local completed = 0
    while remainingElapsed > 0 and completed < 1000 do
      local blueprint = ensureSalesCycle(id, state)
      if not blueprint then break end
      local duration = math.max(1, tonumber(state.salesCycleDurationSeconds) or ENGINE_SALE_MAX_SECONDS)
      local remaining = math.max(0, duration - (state.salesCycleProgressSeconds or 0))
      if remainingElapsed < remaining then
        state.salesCycleProgressSeconds = (state.salesCycleProgressSeconds or 0) + remainingElapsed
        remainingElapsed = 0
      else
        remainingElapsed = remainingElapsed - remaining
        state.salesCycleProgressSeconds = duration
        if not completeCurrentSale(id, state, blueprint) then break end
        completed = completed + 1
      end
    end
    ensureSalesCycle(id, state)
  end

  local function setBlueprintListed(id, blueprintId, listed)
    local state = host.ensureState(id)
    local blueprint = state.blueprints[tostring(blueprintId)]
    if not blueprint then return {success = false, message = "Certified engine blueprint not found."} end
    if listed == true and blueprint.certification and blueprint.certification.status ~= "passed" then
      return {success = false, message = blueprint.certification.reason or "This blueprint no longer passes its torque limit."}
    end
    normalizeBlueprintPrice(blueprint, state)
    blueprint.listed = listed == true
    if tostring(state.salesCurrentBlueprintId or "") == tostring(blueprintId) then resetSalesCycle(state) end
    ensureSalesCycle(id, state)
    return {success = true, message = blueprint.listed and "Engine added to the timed sales queue." or "Engine removed from the sales queue."}
  end

  local function setBlueprintPrice(id, blueprintId, price)
    local state = host.ensureState(id)
    local blueprint = state.blueprints[tostring(blueprintId)]
    if not blueprint then return {success = false, message = "Certified engine blueprint not found."} end
    local priceLimit = salePriceLimit(blueprint, landedCost(blueprint, state.lines), state)
    price = tonumber(price)
    if not price or price ~= price or price < 1 then return {success = false, message = "Enter a positive sale price."} end
    if price > priceLimit then return {success = false, message = string.format("The current maximum for this engine is $%d.", priceLimit)} end
    price = math.floor(price)
    local changed = blueprint.price ~= price
    blueprint.price = price
    if changed and tostring(state.salesCurrentBlueprintId or "") == tostring(blueprintId) then resetSalesCycle(state) end
    ensureSalesCycle(id, state)
    return {success = true, message = changed and "Sale price updated; this engine's countdown restarted." or "Sale price unchanged."}
  end

  return {
    advanceSales = advanceSales,
    destroyWarehousePackage = destroyWarehousePackage,
    ensureSalesCycle = ensureSalesCycle,
    landedCost = landedCost,
    normalizeBlueprintPrice = normalizeBlueprintPrice,
    saleCycleSeconds = saleCycleSeconds,
    salePriceLimit = salePriceLimit,
    setBlueprintListed = setBlueprintListed,
    setBlueprintPrice = setBlueprintPrice,
    supportedMarketPrice = supportedMarketPrice,
  }
end

return part
