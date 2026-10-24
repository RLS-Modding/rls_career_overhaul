-- Dyno history: saved pulls, shop policy, fees and private repair quotes.
-- Each factory retains its session owner so a reload cannot share history or settlement state.
local lib = {}

function lib.create(inputs)
  local dynoState = inputs.dynoState

  -- Saved pull history -----------------------------------------------------------------------------

  local function safeDeepcopy(value)
    if value == nil then
      return nil
    end
    return deepcopy(value)
  end

  local function getCurrentSavePath()
    local _, path = overhaul_career_saveSystem.getCurrentSaveSlot()
    return path
  end

  local function normalizeSavedPull(entry)
    if type(entry) ~= "table" then
      return nil
    end

    local id = tonumber(entry.id)
    if not id then
      return nil
    end

    return {
      id = id,
      savedAt = tonumber(entry.savedAt) or 0,
      inventoryId = tostring(entry.inventoryId or ""),
      vehicleName = entry.vehicleName,
      hubId = entry.hubId,
      peakPower = tonumber(entry.peakPower) or 0,
      peakTorque = tonumber(entry.peakTorque) or 0,
      peakPowerRpm = tonumber(entry.peakPowerRpm) or 0,
      peakTorqueRpm = tonumber(entry.peakTorqueRpm) or 0,
      valid = true,
      measurementComplete = entry.measurementComplete ~= false and entry.valid ~= false,
      pullQuality = (entry.valid == false or entry.measurementComplete == false or entry.pullQuality == "invalid")
        and "warning" or entry.pullQuality,
      qualityFlags = dynoState.normalizeQualityFlags and dynoState.normalizeQualityFlags(entry.qualityFlags) or safeDeepcopy(entry.qualityFlags) or {},
      acceptedSampleCount = tonumber(entry.acceptedSampleCount) or 0,
      rejectedSampleCount = tonumber(entry.rejectedSampleCount) or 0,
      curve = safeDeepcopy(entry.curve) or {},
      rawSamples = safeDeepcopy(entry.rawSamples),
      averagedSamples = safeDeepcopy(entry.averagedSamples),
      averageWindow = entry.averageWindow,
      endReason = entry.endReason,
      cutoffTime = entry.cutoffTime,
      startBuffer = entry.startBuffer,
      tailBuffer = entry.tailBuffer
    }
  end

  -- Keeps the newest entries of one vehicle, up to the per-vehicle limit, and raises the next id past them.
  local function readVehicleEntries(inventoryId, entries)
    local normalizedEntries = {}
    for _, entry in ipairs(entries) do
      local normalized = normalizeSavedPull(entry)
      if normalized then
        normalized.inventoryId = tostring(inventoryId)
        table.insert(normalizedEntries, normalized)
        dynoState.nextPullHistoryId = math.max(dynoState.nextPullHistoryId, normalized.id + 1)
        if #normalizedEntries >= inputs.HISTORY_LIMIT_PER_VEHICLE then
          break
        end
      end
    end
    return normalizedEntries
  end

  local function loadPullHistory()
    dynoState.pullHistoryByVehicle = {}
    dynoState.nextPullHistoryId = 1
    dynoState.pullHistoryLoaded = true
    dynoState.savedPullsRevision = dynoState.savedPullsRevision + 1

    local savePath = getCurrentSavePath()
    if not savePath then
      return
    end

    local data = jsonReadFile(savePath .. inputs.HISTORY_SAVE_FILE)
    if type(data) ~= "table" then
      return
    end

    dynoState.nextPullHistoryId = math.max(1, math.floor(tonumber(data.nextId) or 1))
    local vehicles = type(data.vehicles) == "table" and data.vehicles or {}
    for inventoryId, entries in pairs(vehicles) do
      if type(entries) == "table" then
        local normalizedEntries = readVehicleEntries(inventoryId, entries)
        if #normalizedEntries > 0 then
          dynoState.pullHistoryByVehicle[tostring(inventoryId)] = normalizedEntries
        end
      end
    end
  end

  local function ensurePullHistoryLoaded()
    if not dynoState.pullHistoryLoaded then
      loadPullHistory()
    end
  end

  local function savePullHistory(currentSavePath, writer)
    ensurePullHistoryLoaded()
    if not currentSavePath then
      return false
    end

    local dirPath = currentSavePath .. "/career/rls_career"
    if not writer.exists(dirPath) then
      writer.mkdir(dirPath)
    end

    return overhaul_career_saveSystem.jsonWriteFileSafe(currentSavePath .. inputs.HISTORY_SAVE_FILE, {
      version = inputs.HISTORY_VERSION,
      nextId = dynoState.nextPullHistoryId,
      vehicles = dynoState.pullHistoryByVehicle
    }, true) == true
  end

  local function getPullHistoryForVehicle(inventoryId)
    ensurePullHistoryLoaded()
    if inventoryId == nil then
      return {}
    end
    return safeDeepcopy(dynoState.pullHistoryByVehicle[tostring(inventoryId)] or {})
  end

  -- UI payloads keep the plotted curve; captured samples remain private to saves and Lua consumers.
  local UI_PULL_FIELDS = {
    "id", "savedAt", "inventoryId", "vehicleName", "hubId", "savedPullId",
    "peakPower", "peakTorque", "peakPowerRpm", "peakTorqueRpm", "valid",
    "measurementComplete", "pullQuality", "qualityFlags", "acceptedSampleCount",
    "rejectedSampleCount", "curve", "endReason", "liveSample"
  }

  local function pullSummaryForUi(pull)
    if not pull then return nil end
    local summary = {}
    for _, field in ipairs(UI_PULL_FIELDS) do
      summary[field] = safeDeepcopy(pull[field])
    end
    return summary
  end

  local function getPullHistoryForUi(inventoryId)
    ensurePullHistoryLoaded()
    local summaries = {}
    for _, pull in ipairs(dynoState.pullHistoryByVehicle[tostring(inventoryId)] or {}) do
      summaries[#summaries + 1] = pullSummaryForUi(pull)
    end
    return summaries
  end

  -- Shop ownership and policy ----------------------------------------------------------------------

  local function isShopOwnershipReady()
    if not overhaul_career_career.isActive() then
      return true
    end
    return overhaul_career_business_manager.isBusinessOwnershipReady() == true
  end

  local function getDynoBusinessBundle()
    local station = dynoState.station
    local mapId = getCurrentLevelIdentifier()
    if station and station.mapId ~= mapId then station = nil end
    if not station then return nil, mapId end
    if station.businessBundleId then
      for _, bundle in ipairs(inputs.bundles.getAll()) do
        if bundle.mapId == mapId and bundle.businessId == station.businessBundleId then return bundle, mapId end
      end
      return nil, mapId
    end
    return inputs.bundles.forDyno(mapId, station.triggerName, station.bundleSitesFile or station.sitesFile,
      station.parkingSpotName), mapId
  end

  local function shopNeedsOwnershipResolution()
    local bundle = getDynoBusinessBundle()
    return bundle ~= nil and not isShopOwnershipReady()
  end

  local function flushOwnershipWaitCallbacks()
    local callbacks = dynoState.ownershipWaitCallbacks
    dynoState.ownershipWaitCallbacks = {}
    for _, callback in ipairs(callbacks) do
      if callback then callback() end
    end
  end

  local function waitForShopOwnership(callback)
    if not shopNeedsOwnershipResolution() then
      if callback then callback() end
      return true
    end
    if callback then
      dynoState.ownershipWaitCallbacks[#dynoState.ownershipWaitCallbacks + 1] = callback
    end
    return true
  end

  local function resolveShopPolicy()
    local bundle, mapId = getDynoBusinessBundle()
    if bundle and not isShopOwnershipReady() then
      return {
        mapId = mapId,
        businessId = bundle.businessId,
        ownershipReady = false,
        ownerBenefit = false,
        unlimitedPulls = false,
        fee = 0
      }
    end
    local owner = inputs.bundles.isOwned(bundle)
    return {
      mapId = mapId,
      businessId = bundle and bundle.businessId,
      ownershipReady = true,
      ownerBenefit = owner,
      unlimitedPulls = owner,
      fee = owner and 0 or inputs.SESSION_FEE
    }
  end

  local function currentPolicy()
    return inputs.dynoSession.active and inputs.dynoSession.policy or resolveShopPolicy()
  end

  local function requireResolvedShopPolicy()
    local policy = resolveShopPolicy()
    if policy.ownershipReady == false then
      return nil, "Business ownership is still loading."
    end
    return policy
  end

  -- Fees, charges and refunds ----------------------------------------------------------------------

  local function getMoneyPrice(amount)
    return {
      money = {
        amount = math.max(0, tonumber(amount) or 0),
        canBeNegative = false
      }
    }
  end

  local function canPayAmount(amount)
    if amount <= 0 then return true end
    return overhaul_career_economy_payment.canPay(getMoneyPrice(amount)) == true
  end

  local function canPayFee()
    return canPayAmount(currentPolicy().fee)
  end

  local function chargeAmount(amount, label, tags, context, category)
    amount = math.max(0, tonumber(amount) or 0)
    if amount <= 0 then
      return true
    end
    if not canPayAmount(amount) then
      return false
    end
    if context then context.locationId = context.locationId or (dynoState.station and dynoState.station.id) end
    return overhaul_career_economy_payment.pay(getMoneyPrice(amount), require("overhaul/lib/finance/metadata").tag({
      label = label,
      tags = tags or {"dyno", "buying"}
    }, category or "service", {vehicleId = context and context.inventoryId, locationId = context and context.locationId or (dynoState.station and dynoState.station.id)})) == true
  end

  local function refundAmount(amount, label, context)
    amount = math.max(0, tonumber(amount) or 0)
    if amount <= 0 then
      return true
    end
    -- Refunds run from the unload and level-end hooks, where the payment module may already be gone.
    if not overhaul_career_economy_payment then
      return false
    end
    return overhaul_career_economy_payment.reward({money = {amount = amount}}, require("overhaul/lib/finance/metadata").tag({
      label = label or "Dyno refund",
      tags = {"dyno", "refund"}
    }, "refund", {vehicleId = context and context.inventoryId, locationId = context and context.locationId}), true) == true
  end

  -- Private repair quote ---------------------------------------------------------------------------

  -- Tires are not private repairs: only selectable non-tire damage lines are quoted.
  local function selectableDamageLines(assessment)
    local selectedIds = {}
    local damageLines = {}
    for _, line in ipairs(assessment.lines or {}) do
      if line.selectable and line.kind ~= "tire" and line.id then
        table.insert(selectedIds, line.id)
        table.insert(damageLines, safeDeepcopy(line))
      end
    end
    return selectedIds, damageLines
  end

  local function clearRepairQuote(inventoryId, fee)
    return {
      ok = true,
      required = false,
      selectedIds = {},
      damageLines = {},
      baseCost = 0,
      laborMultiplier = 1,
      repairCost = 0,
      dynoFee = fee,
      totalCost = fee,
      revision = "clear:" .. tostring(inventoryId)
    }
  end

  -- The revision changes whenever a quoted line, its cost or the labor multiplier changes.
  local function repairRevision(quote, laborMultiplier, repairCost)
    local revisionRows = {}
    for _, line in ipairs(quote.selectedLines or {}) do
      table.insert(revisionRows, string.format("%s:%d", tostring(line.id), math.floor((tonumber(line.cost) or 0) + 0.5)))
    end
    table.sort(revisionRows)
    return table.concat(revisionRows, "|") .. string.format("|%.2f|%d", laborMultiplier, repairCost)
  end

  local function buildRepairQuote(inventoryId)
    local policy = currentPolicy()
    if policy.ownershipReady == false then
      return {ok = false, required = false, message = "Business ownership is still loading."}
    end
    local fee = policy.fee
    local finite = overhaul_career_repair_finiteDamage

    local assessment = finite.assess(inventoryId)
    if not assessment or not assessment.ok then
      return {ok = false, required = false, message = assessment and assessment.reason or "Vehicle damage could not be assessed."}
    end

    local selectedIds, damageLines = selectableDamageLines(assessment)
    if #selectedIds == 0 then
      return clearRepairQuote(inventoryId, fee)
    end

    local quote = finite.quoteSelection(inventoryId, selectedIds)
    if not quote or not quote.ok then
      return {ok = false, required = true, message = quote and quote.message or "Private repair could not be quoted."}
    end

    local laborMultiplier = quote.hasBrokenParts and 1.25 or 1.1
    local baseCost = tonumber(quote.totalPreLabor) or 0
    local repairCost = math.ceil(baseCost * laborMultiplier - 0.000001)

    return {
      ok = true,
      required = true,
      selectedIds = selectedIds,
      damageLines = damageLines,
      baseCost = baseCost,
      laborMultiplier = laborMultiplier,
      repairCost = repairCost,
      dynoFee = fee,
      totalCost = repairCost + fee,
      hasBrokenParts = quote.hasBrokenParts == true,
      selectedCount = #selectedIds,
      revision = repairRevision(quote, laborMultiplier, repairCost)
    }
  end

  local repairQuoteCache

  local function sameDamageState(current, previous)
    if type(current) ~= "table" or type(previous) ~= "table" then return current == previous end
    for key, value in pairs(current) do
      if not sameDamageState(value, previous[key]) then return false end
    end
    for key in pairs(previous) do
      if current[key] == nil then return false end
    end
    return true
  end

  local function getRepairQuoteForUi(inventoryId)
    local vehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
    local policy = currentPolicy()
    -- Inventory conditions can be repaired in place, so table identity is not a damage revision.
    local damageState = {
      inventoryId = inventoryId,
      conditions = vehicle and vehicle.partConditions,
      partsTree = vehicle and vehicle.config and vehicle.config.partsTree,
      inspection = dynoState.conditionRefreshToken,
      fee = policy.fee,
      ownershipReady = policy.ownershipReady
    }
    if repairQuoteCache and sameDamageState(damageState, repairQuoteCache.damageState) then
      return repairQuoteCache.quote
    end
    local quote = buildRepairQuote(inventoryId)
    -- An unavailable assessment must be retried when its dependencies become ready.
    repairQuoteCache = quote.ok and {
      damageState = safeDeepcopy(damageState), quote = quote
    } or nil
    return quote
  end

  return {
    safeDeepcopy = safeDeepcopy,
    loadPullHistory = loadPullHistory,
    ensurePullHistoryLoaded = ensurePullHistoryLoaded,
    savePullHistory = savePullHistory,
    getPullHistoryForVehicle = getPullHistoryForVehicle,
    getPullHistoryForUi = getPullHistoryForUi,
    pullSummaryForUi = pullSummaryForUi,
    shopNeedsOwnershipResolution = shopNeedsOwnershipResolution,
    flushOwnershipWaitCallbacks = flushOwnershipWaitCallbacks,
    waitForShopOwnership = waitForShopOwnership,
    currentPolicy = currentPolicy,
    requireResolvedShopPolicy = requireResolvedShopPolicy,
    canPayAmount = canPayAmount,
    canPayFee = canPayFee,
    chargeAmount = chargeAmount,
    refundAmount = refundAmount,
    buildRepairQuote = buildRepairQuote,
    getRepairQuoteForUi = getRepairQuoteForUi,
  }
end

return lib
