-- Engine certification: recipe ratings, torque limits and compatible hardware.
-- Map: state/save; curves; resolved JBeam; boost estimate; migration; jobs; lifecycle.
-- Uses stock variable and slot merging on the stored subtree; no vehicle spawn.

local M = {}

local jbeamIO = require("jbeam/io")
-- Config -------------------------------------------------------------------------------------------

local SAVE_VERSION = 3
local ANALYSIS_VERSION = 5
local SAVE_PATH = "/career/rls_career/engineCertifications.json"
local CERTIFICATION_SECONDS = 60
local CERTIFICATION_FEE_RATE = 0.10
local CERTIFICATION_TORQUE_TOLERANCE = 0.01
local HORSEPOWER_TORQUE_RPM_DIVISOR = 7127
local ATMOSPHERE_PSI = 14.7
local BOOST_TORQUE_GAIN = 0.55
local MAXIMUM_ESTIMATED_BOOST_PSI = 50
local FORCED_INDUCTION_KEYS = {"maxWastegatePressure", "wastegatePressure", "wastegateLimit", "wastegateStart", "maxBoost"}

-- State -------------------------------------------------------------------------------------------

-- Saved with the career: pending and running stress tests, keyed by package id.
local jobs = {}
local activeSeconds = 0
local initialized = false
local orphanCheckPending = false
-- Validate saved content once per loaded record, without resolving every UI tick.
local validatedContent = setmetatable({}, {__mode = "k"})

-- Save data -----------------------------------------------------------------------------------------

local function saveData(savePath)
  if not savePath then return end
  overhaul_career_saveSystem.jsonWriteFileSafe(savePath .. SAVE_PATH, {version = SAVE_VERSION, activeSeconds = activeSeconds, jobs = jobs}, true)
end

-- Jobs that were already completed stay out of the list; unfinished ones restart as pending.
local function loadData()
  jobs = {}
  orphanCheckPending = true
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  local data = savePath and jsonReadFile(savePath .. SAVE_PATH) or nil
  activeSeconds = math.max(0, tonumber(data and data.activeSeconds) or 0)
  for id, source in pairs(data and data.jobs or {}) do
    local job = deepcopy(source)
    if not job.completed then
      if not job.readyAtActive then
        job.readyAtActive = activeSeconds + CERTIFICATION_SECONDS
      end
      job.status = "pending"
      jobs[tostring(id)] = job
    end
  end
end

-- Torque curves -------------------------------------------------------------------------------------

-- Torque curve from a CSV file reference such as include("/vehicles/x/torque.csv"), or the table as given.
local function readCurveFile(curve)
  if type(curve) ~= "string" then return curve end
  local includePath = curve:match("include%s*%(%s*['\"]([^'\"]+)['\"]%s*%)")
  if not includePath then return nil end
  if includePath:sub(1, 1) ~= "/" then includePath = "/" .. includePath end
  local csv = readFile(includePath)
  if type(csv) ~= "string" or csv == "" then return nil end
  local result = {}
  for line in csv:gmatch("[^\r\n]+") do
    local first, second = line:match("^%s*([^,]+)%s*,%s*([^,]+)")
    if first and second then
      first = first:gsub('[%s\"]', '')
      second = second:gsub('[%s\"]', '')
      local rpm = tonumber(first)
      local torque = tonumber(second)
      if rpm and torque then result[#result + 1] = {rpm = rpm, torque = torque} end
    end
  end
  return result
end

-- Accepts {rpm, amount} rows, {rpm = ..., torque = ...} rows, or an rpm-keyed table.
local function normalizedCurve(curve)
  curve = readCurveFile(curve)
  if type(curve) ~= "table" then return nil end
  local result = {}
  for key, value in pairs(curve) do
    local rpm, amount
    if type(value) == "table" then
      rpm, amount = tonumber(value.rpm or value[1]), tonumber(value.torque or value[2])
    else
      rpm, amount = tonumber(key), tonumber(value)
    end
    if rpm and amount then result[#result + 1] = {rpm = rpm, amount = amount} end
  end
  table.sort(result, function(a, b) return a.rpm < b.rpm end)
  return #result > 0 and result or nil
end

-- Read the single combustion device curve after part merging.
local function readBaseCurve(engine, curve)
  curve = readCurveFile(curve)
  if type(curve) ~= "table" then return end
  local samples, peakTorque, peakHp = {}, 0, 0
  for key, value in pairs(curve) do
    local rpm, torque
    if type(value) == "table" then
      rpm, torque = tonumber(value.rpm or value[1]), tonumber(value.torque or value[2])
    else
      rpm, torque = tonumber(key), tonumber(value)
    end
    if rpm and torque and rpm >= 0 then
      local hp = torque * rpm / HORSEPOWER_TORQUE_RPM_DIVISOR
      samples[#samples + 1] = {rpm = rpm, torque = torque, horsepower = hp}
      peakTorque, peakHp = math.max(peakTorque, torque), math.max(peakHp, hp)
    end
  end
  if #samples > #engine.bestSamples or peakTorque > engine.bestPeakTorque then
    table.sort(samples, function(a, b) return a.rpm < b.rpm end)
    engine.bestSamples, engine.bestPeakTorque, engine.bestPeakHp = samples, peakTorque, peakHp
  end
end

local function curveValue(curve, rpm)
  if rpm <= curve[1].rpm then return curve[1].amount end
  for index = 2, #curve do
    local right, left = curve[index], curve[index - 1]
    if rpm <= right.rpm then
      local range = right.rpm - left.rpm
      local blend = range > 0 and (rpm - left.rpm) / range or 0
      return left.amount + (right.amount - left.amount) * blend
    end
  end
  return curve[#curve].amount
end

-- Applies the authored torque modifiers to the base curve and recomputes its peaks.
local function applyTorqueModifiers(engine)
  if #engine.bestSamples == 0 or (#engine.additiveTorqueCurves == 0 and #engine.multiplierTorqueCurves == 0) then return end
  engine.bestPeakTorque, engine.bestPeakHp = 0, 0
  for _, sample in ipairs(engine.bestSamples) do
    local torque = sample.torque
    for _, curve in ipairs(engine.multiplierTorqueCurves) do torque = torque * curveValue(curve, sample.rpm) end
    for _, curve in ipairs(engine.additiveTorqueCurves) do torque = torque + curveValue(curve, sample.rpm) end
    sample.torque = torque
    sample.horsepower = torque * sample.rpm / HORSEPOWER_TORQUE_RPM_DIVISOR
    engine.bestPeakTorque = math.max(engine.bestPeakTorque, sample.torque)
    engine.bestPeakHp = math.max(engine.bestPeakHp, sample.horsepower)
  end
end

-- Resolved JBeam ------------------------------------------------------------------------------------

-- Keep the stock journal order and slot scopes, but never fill a missing stored
-- child with today's default: that would certify hardware the player does not own.
local function resolveRecipe(recipe, ioCtx, hardwareOnly)
  local slots = require("jbeam/slotSystem")
  local variables = require("jbeam/variables")

  local function visit(node, path, level, inheritedOptions)
    if level > 50 then error("Engine part nesting exceeds the JBeam limit.") end
    local part = node.name and jbeamIO.getPart(ioCtx, node.name)
    if not part then error("Selected engine part is unavailable: " .. tostring(node.name)) end
    part = deepcopy(part)
    local visited, journal, components = {}, {}, {}
    for _, slot in ipairs(part.slots2 or part.slots or {}) do
      local id = slot.name or slot.type
      local child = node.children and node.children[id]
      if child and child.name and child.name ~= "" then
        visited[id] = true
        local options = tableMerge(deepcopy(inheritedOptions or {}), deepcopy(slot))
        for _, key in ipairs({"name", "type", "allowTypes", "denyTypes", "default", "description", "maxRecursion", "coreSlot", "variables"}) do options[key] = nil end
        local childPath = path .. id .. "/" .. child.name
        local childPart, childJournal, childComponents = visit(child, childPath .. "/", level + 1, options)
        if not slots.partFitsSlot(childPart, slot) then error("Stored engine part no longer fits slot: " .. tostring(id)) end
        local entry = {part, childPart, level, options, childPath, deepcopy(slot)}
        components[#components + 1] = entry
        for _, item in ipairs(childComponents) do components[#components + 1] = item end
        for _, item in ipairs(childJournal) do journal[#journal + 1] = item end
        journal[#journal + 1] = entry
      end
    end
    for id, child in pairs(node.children or {}) do
      if child.name and child.name ~= "" and not visited[id] then error("Stored engine slot is unavailable: " .. tostring(id)) end
    end
    -- Each caller receives only its subtree's postorder journal.
    return part, journal, components
  end
  -- The stock loader uses preorder for components and postorder for merging.
  local root, entries, components = visit(recipe.tree, "/", 1)
  if hardwareOnly then return root end
  local config = {vars = deepcopy(recipe.tuning or {})}
  local vars = variables.getAllVariables(root, entries, config)
  variables.processComponents(root, components, config, vars)
  variables.processParts(root, entries, config, vars)
  if not slots.unifyPartJournal(ioCtx, entries) then error("Engine part merging failed.") end
  return root
end

-- Promotion identity owns hardware equality, independently of certification's
-- exact recipe/tune fingerprint. Every selected part in the engine subtree is
-- hardware (including adapters, controllers and unknown third-party slots).
-- Discover slots with the certification resolver above rather than maintaining
-- a stock-name/category allowlist that would omit prefixed or modded hardware.
-- The root part ID identifies the engine family; descendants retain relative
-- slot membership and multiplicity. Vehicle/attachment paths, display data,
-- paint and $ tuning values are never read. Length framing avoids hash clashes.
-- Missing assets leave the blueprint intact and retryable on the next load.
function M.computeHardwareIdentity(recipe)
  local ok, identity = pcall(function()
    assert(type(recipe) == "table" and type(recipe.tree) == "table")
    local vehicleDir = string.format("/vehicles/%s/", recipe.vehicleModel)
    assert(FS:directoryExists(vehicleDir))
    local ioCtx = assert(jbeamIO.startLoading({vehicleDir, "/vehicles/common/"}))
    resolveRecipe(recipe, ioCtx, true)
    local function frame(value)
      value = tostring(value)
      return #value .. ":" .. value
    end
    local function encode(node)
      local children = {}
      for slot, child in pairs(node.children or {}) do
        if child.name and child.name ~= "" then children[#children + 1] = frame(slot) .. frame(encode(child)) end
      end
      table.sort(children)
      return frame(node.name) .. table.concat(children)
    end
    return "engine-hardware-1:" .. encode(recipe.tree)
  end)
  if ok then return identity end
  return nil, "Engine hardware could not be identified."
end

-- Boost estimate -------------------------------------------------------------------------------------

-- A boost value authored as a number, or as a tuning variable with an optional offset such as "$boost + 2".
local function resolveAuthoredNumber(recipe, value)
  local numeric = tonumber(value)
  if numeric then return numeric end
  if type(value) ~= "string" then return nil end
  local variableName = value:match("(%$[%w_]+)")
  local base = variableName and tonumber(recipe.tuning and recipe.tuning[variableName])
  if not base then return nil end
  local offset = tonumber(value:match("([%+%-]%s*[%d%.]+)")) or 0
  return base + offset
end

local function devicePressure(recipe, device, peakTorqueRpm)
  local pressure
  for _, key in ipairs(FORCED_INDUCTION_KEYS) do
    pressure = resolveAuthoredNumber(recipe, device[key])
    if pressure then break end
  end
  if not pressure and tonumber(device.pressurePSIPer1kRPM) then
    pressure = tonumber(device.pressurePSIPer1kRPM) * math.max(0, peakTorqueRpm)
      * math.max(0.1, tonumber(device.gearRatio) or 1) / 1000
  end
  return tonumber(pressure) or 0
end

-- The highest boost any authored device reaches, capped. Used for a risk estimate, not a dyno run.
local function estimateBoostPsi(engine, recipe, peakTorqueRpm)
  local estimatedBoostPsi = 0
  for _, device in ipairs(engine.forcedInduction) do
    estimatedBoostPsi = math.max(estimatedBoostPsi, devicePressure(recipe, device, peakTorqueRpm))
  end
  return math.min(MAXIMUM_ESTIMATED_BOOST_PSI, estimatedBoostPsi)
end

-- Reads the authored engine into `engine`: ratings, rev limits, torque curves and forced induction.
local function collectEngineData(recipe, ioCtx)
  local resolved = resolveRecipe(recipe, ioCtx)
  local devices = {}
  require("jbeam/tableSchema").processTableWithSchemaDestructive(resolved.powertrain or {}, devices)
  local deviceName, deviceData
  for _, row in pairs(devices) do
    -- Mods can supply prefixed combustion factories (for example Ravix's
    -- RLS_combustionEngine); the device name is still authored by the row.
    if type(row.type) == "string" and row.type:lower():find("combustionengine", 1, true) then
      if deviceName then error("Multiple combustion engines require separate certification.") end
      deviceName = row.name
      -- powertrain.init overlays the named section onto the device row.
      deviceData = tableMergeRecursive(deepcopy(row), resolved[deviceName] or {})
    end
  end
  if not deviceData then error("No resolved combustion engine was found.") end
  local engine = {
    deviceName = deviceName, rating = tonumber(deviceData.maxTorqueRating),
    declaredMaxRpm = tonumber(deviceData.maxRPM), limiterRpm = tonumber(deviceData.revLimiterRPM),
    bestSamples = {}, bestPeakTorque = 0, bestPeakHp = 0,
    additiveTorqueCurves = {}, multiplierTorqueCurves = {}, forcedInduction = {}
  }
  readBaseCurve(engine, deviceData.torque)
  for _, key in ipairs({"torqueModIntake", "torqueModExhaust"}) do
    local curve = normalizedCurve(deviceData[key])
    if curve then engine.additiveTorqueCurves[#engine.additiveTorqueCurves + 1] = curve end
  end
  local multiplier = normalizedCurve(deviceData.torqueModMult)
  if multiplier then engine.multiplierTorqueCurves[1] = multiplier end
  if deviceData.hasRevLimiter == false then engine.limiterRpm = nil end
  for _, key in ipairs({"turbocharger", "supercharger"}) do
    local section = deviceData[key] and resolved[deviceData[key]]
    if type(section) == "table" then engine.forcedInduction[#engine.forcedInduction + 1] = section end
  end
  applyTorqueModifiers(engine)
  return engine
end

local function peakTorqueRpmOf(samples, peakTorque)
  local peakTorqueRpm = 0
  for _, sample in ipairs(samples) do
    if sample.torque >= peakTorque then peakTorqueRpm = sample.rpm end
  end
  return peakTorqueRpm
end

-- Hash canonical resolved inputs, including curves, boost variables and hardware IDs.
-- Sorted keys avoid depending on Lua iteration order or JSON save ordering.
local function contentFingerprint(engine, recipe)
  local hash = 5381
  local function append(value)
    for index = 1, #value do hash = (hash * 33 + value:byte(index)) % 4294967296 end
  end
  local function visit(value)
    local kind = type(value)
    append(kind .. ":")
    if kind == "table" then
      local keys = {}
      for key in pairs(value) do keys[#keys + 1] = key end
      table.sort(keys, function(left, right) return type(left) .. tostring(left) < type(right) .. tostring(right) end)
      for _, key in ipairs(keys) do visit(key); visit(value[key]) end
      append(";")
    else
      local text = kind == "number" and string.format("%.17g", value) or tostring(value)
      append(#text .. ":" .. text)
    end
  end
  visit({engine = engine, tree = recipe.tree, tuning = recipe.tuning, vehicleModel = recipe.vehicleModel})
  return string.format("resolved-1:%08x", hash)
end

-- Resolve once for content validation; reuse these inputs if analysis is needed.
local function loadRecipeEngine(recipe, existingIoCtx)
  if type(recipe) ~= "table" or not recipe.vehicleModel or not recipe.tree then
    return nil, "Couldn't read this engine package; try re-storing the engine."
  end
  local ok, engine, reason = pcall(function()
    local vehicleDir = string.format("/vehicles/%s/", recipe.vehicleModel)
    if not FS:directoryExists(vehicleDir) then return nil, "The source vehicle mod is unavailable." end
    local ioCtx = existingIoCtx or jbeamIO.startLoading({vehicleDir, "/vehicles/common/"})
    if not ioCtx then return nil, "Couldn't read this engine package; try re-storing the engine." end
    return collectEngineData(recipe, ioCtx)
  end)
  if not ok then
    log("W", "engineCertification", "Engine package resolution failed: " .. tostring(engine))
    return nil, "Couldn't read this engine package; try re-storing the engine."
  end
  if not engine then return nil, reason end
  return engine
end

-- Values are canonical BeamNG units: Nm and mechanical horsepower.
local function analyzeRecipe(recipe, existingIoCtx, preparedEngine, preparedFingerprint)
  local engine, err = preparedEngine, nil
  if not engine then engine, err = loadRecipeEngine(recipe, existingIoCtx) end
  local fingerprint = preparedFingerprint or (engine and contentFingerprint(engine, recipe))
  local function unknown(reason)
    return {result = "unknown", status = "unknown", analysisVersion = ANALYSIS_VERSION,
      reason = "Rating unknown. " .. reason, samples = {}, contentFingerprint = fingerprint}
  end
  if not engine then return unknown(err) end
  local rating = engine.rating
  if not rating or rating <= 0 or rating ~= rating or rating == math.huge then
    return unknown("This engine's mod doesn't provide a usable torque rating.")
  end
  if #engine.bestSamples == 0 or engine.bestPeakTorque <= 0 then return unknown("This engine's mod doesn't provide a readable torque curve.") end
  local limiterRpm = engine.limiterRpm or engine.declaredMaxRpm or engine.bestSamples[#engine.bestSamples].rpm

  -- A detune must remove unreachable torque, including a sample at the limiter.
  local curve = {}
  for _, sample in ipairs(engine.bestSamples) do curve[#curve + 1] = {rpm = sample.rpm, amount = sample.torque} end
  local samples = {}
  for _, sample in ipairs(engine.bestSamples) do
    if sample.rpm < limiterRpm then samples[#samples + 1] = sample end
  end
  samples[#samples + 1] = {rpm = limiterRpm, torque = curveValue(curve, limiterRpm)}
  engine.bestSamples, engine.bestPeakTorque, engine.bestPeakHp = samples, 0, 0
  for _, sample in ipairs(samples) do
    sample.horsepower = sample.torque * sample.rpm / HORSEPOWER_TORQUE_RPM_DIVISOR
    engine.bestPeakTorque = math.max(engine.bestPeakTorque, sample.torque)
    engine.bestPeakHp = math.max(engine.bestPeakHp, sample.horsepower)
  end

  -- A full dyno spawn would be expensive and brittle for retail stock. Estimate the added cylinder pressure from authored boost hardware instead. This is intentionally conservative and bounded; it is used for a risk warning, not as a replacement for BeamNG's runtime powertrain simulation.
  local estimatedBoostPsi = estimateBoostPsi(engine, recipe, peakTorqueRpmOf(engine.bestSamples, engine.bestPeakTorque))
  local boostMultiplier = 1 + estimatedBoostPsi / ATMOSPHERE_PSI * BOOST_TORQUE_GAIN
  local peakTorque = engine.bestPeakTorque * boostMultiplier
  local peakHp = engine.bestPeakHp * boostMultiplier
  for _, sample in ipairs(engine.bestSamples) do
    sample.torque = sample.torque * boostMultiplier
    sample.horsepower = sample.horsepower * boostMultiplier
  end

  local torqueLimit = rating * (1 + CERTIFICATION_TORQUE_TOLERANCE)
  local failed = peakTorque > torqueLimit
  local scale = torqueLimit / peakTorque

  return {
    result = failed and "failed" or "passed",
    contentFingerprint = fingerprint,
    reason = failed and "Estimated torque exceeds the installed engine rating (including the 1% tolerance)." or nil,
    peakHorsepower = peakHp,
    peakTorque = peakTorque,
    rating = rating,
    torqueLimit = torqueLimit,
    torqueUtilization = peakTorque / rating,
    estimatedSafePower = peakHp * scale,
    estimatedBoostPsi = estimatedBoostPsi,
    limiterRpm = limiterRpm,
    declaredMaxRpm = engine.declaredMaxRpm,
    analysisVersion = ANALYSIS_VERSION,
    ratingDevice = engine.deviceName,
    samples = engine.bestSamples
  }
end

-- Recompute cached outcomes without charging again or changing recipe identity.
local function refreshAnalysis(record, recipe)
  if not record then return record end
  if record.analysisVersion == ANALYSIS_VERSION and validatedContent[record] then return record end
  local engine, loadError = loadRecipeEngine(recipe)
  local fingerprint = engine and contentFingerprint(engine, recipe)
  validatedContent[record] = true
  if record.analysisVersion == ANALYSIS_VERSION and fingerprint and record.contentFingerprint == fingerprint then return record end
  local analysis, err
  if engine then analysis, err = analyzeRecipe(recipe, nil, engine, fingerprint) else err = loadError end
  if not analysis then
    log("W", "engineCertification", "Engine package analysis failed: " .. tostring(err))
    analysis = {result = "unknown", reason = "Rating unknown. Couldn't read this engine package; try re-storing the engine.",
      samples = {}, analysisVersion = ANALYSIS_VERSION}
  end
  for _, key in ipairs({"rating", "torqueLimit", "peakTorque", "peakHorsepower", "torqueUtilization", "estimatedSafePower", "limiterRpm", "samples", "reason", "usedLegacyRating", "contentFingerprint"}) do record[key] = nil end
  for key, value in pairs(analysis) do record[key] = deepcopy(value) end
  record.status = analysis.result
  return record
end

-- Jobs ----------------------------------------------------------------------------------------------

local function completeJob(packageId, job)
  if job.completed then return end
  job.completed = true
  job.status = job.analysis.result
  job.completedAtActive = activeSeconds
  local certification = deepcopy(job.analysis)
  certification.status = job.status
  certification.recipeSignature = job.recipeSignature
  certification.completedAtActive = job.completedAtActive
  certification.fee = job.fee
  certification.shopId = job.shopId
  overhaul_career_parts_engines_enginePackages.setEngineShopCertification(packageId, certification)
  jobs[tostring(packageId)] = nil
  guihooks.trigger("toastrMsg", {
    type = job.status == "passed" and "success" or "warning",
    title = "Engine stress test complete",
    msg = job.status == "unknown" and (job.analysis.reason or "Rating unknown. The package was returned intact.")
      or job.status == "passed" and (job.packageName .. " passed its stress test.")
      or (job.packageName .. " exceeded its declared stress limit.")
  })
end

-- A pending certification on a package with no running job was left by an interrupted save; clear it.
local function clearOrphanPendingCertifications()
  orphanCheckPending = false
  local packagesModule = overhaul_career_parts_engines_enginePackages
  if not packagesModule or not packagesModule.listPackages then return end
  for _, package in ipairs(packagesModule.listPackages({ownerType = "personal"}) or {}) do
    local certification = package.engineShopCertification
    if certification and certification.status ~= "pending" then
      refreshAnalysis(certification, packagesModule.getRecipeFromPackage(package))
    end
    if type(certification) == "table" and certification.status == "pending" and not jobs[tostring(package.id)] then
      package.engineShopCertification = nil
      log("W", "engineCertification", "Cleared pending stress test with no job for package " .. tostring(package.id))
    end
  end
end

local function processJobs()
  if orphanCheckPending then clearOrphanPendingCertifications() end
  for packageId, job in pairs(jobs) do
    if job.analysis and (job.analysis.analysisVersion ~= ANALYSIS_VERSION
      or not validatedContent[job.analysis]) then
      local package = overhaul_career_parts_engines_enginePackages.getPackage(packageId)
      refreshAnalysis(job.analysis, package and overhaul_career_parts_engines_enginePackages.getRecipeFromPackage(package))
    end
    if not overhaul_career_parts_engines_enginePackages.getPackage(packageId) then
      jobs[packageId] = nil
    elseif not job.completed and activeSeconds >= (tonumber(job.readyAtActive) or math.huge) then
      completeJob(packageId, job)
    end
  end
end

-- Why a package cannot start a stress test, or nil when it can.
local function certificationBlocker(package, recipe)
  local prior = package.engineShopCertification
  if prior and prior.analysisVersion == ANALYSIS_VERSION and prior.recipeSignature == recipe.signature and (prior.status == "passed" or prior.status == "failed") then
    return prior.status == "passed"
      and "This exact configuration already passed its stress test."
      or "This exact configuration already failed its stress test. Change the package before testing it again."
  end
end

local function startPersonalCertification(packageId, shopId)
  processJobs()
  packageId = tostring(packageId or "")
  local package = overhaul_career_parts_engines_enginePackages.getPackage(packageId)
  if not package or package.ownerType == "business" then return {success = false, message = "Choose a personal Engine Package."} end
  if overhaul_career_parts_engines_enginePackages.getPackageStatus(package) ~= "stored" then
    return {success = false, message = "Certification requires a stored Engine Package."}
  end
  local existing = jobs[packageId]
  if existing and not existing.completed then return {success = false, message = "This package is already being certified."} end
  local freshValue, recipe = overhaul_career_parts_engines_enginePackages.getFreshPackageValue(package)
  if not freshValue then return {success = false, message = recipe or "Package value could not be calculated."} end
  local blocker = certificationBlocker(package, recipe)
  if blocker then return {success = false, message = blocker} end
  local analysis, err = analyzeRecipe(recipe)
  if not analysis or analysis.result == "unknown" then return {success = false, message = err or analysis.reason} end
  local fee = math.max(1, math.floor(freshValue * CERTIFICATION_FEE_RATE + 0.5))
  if not overhaul_career_economy_payment.pay({money = {amount = fee, canBeNegative = false}}, require("overhaul/lib/finance/metadata").tag({
    label = "Engine stress test", tags = {"engineCertification", "maintenance"}
  }, "service", {vehicleRelated = false, locationId = shopId})) then return {success = false, message = "You cannot afford the stress-test fee."} end
  jobs[packageId] = {
    packageId = packageId, packageName = package.name, shopId = tostring(shopId or ""),
    recipeSignature = recipe.signature, fee = fee, submittedAtActive = activeSeconds, readyAtActive = activeSeconds + CERTIFICATION_SECONDS,
    status = "pending", completed = false, analysis = analysis
  }
  overhaul_career_parts_engines_enginePackages.setEngineShopCertification(packageId, {
    status = "pending", recipeSignature = recipe.signature, submittedAtActive = activeSeconds,
    readyAtActive = activeSeconds + CERTIFICATION_SECONDS, fee = fee, shopId = tostring(shopId or "")
  })
  return {success = true, message = string.format("Stress test started for $%d. It will finish after 60 seconds.", fee)}
end

local function getPersonalJobs()
  processJobs()
  local result = {}
  for _, job in pairs(jobs) do
    local copy = deepcopy(job)
    copy.remainingSeconds = copy.completed and 0 or math.max(0, (copy.readyAtActive or activeSeconds) - activeSeconds)
    result[#result + 1] = copy
  end
  table.sort(result, function(a, b) return tostring(a.packageId) < tostring(b.packageId) end)
  return result
end

local function packageGuard(package)
  local job = package and jobs[tostring(package.id)]
  if job and not job.completed then return false, "This Engine Package is locked during certification." end
  return true
end

-- Update -------------------------------------------------------------------------------------------

local function onUpdate(dtReal)
  if not (overhaul_career_career and overhaul_career_career.isActive()) then return end
  if simTimeAuthority.getPause() then return end
  activeSeconds = activeSeconds + math.max(0, tonumber(dtReal) or 0)
  processJobs()
end

-- Lifecycle ------------------------------------------------------------------------

local function initialize()
  if initialized then return end
  initialized = true
  loadData()
  overhaul_career_parts_engines_enginePackages.registerPackageReferenceGuard(packageGuard)
end

-- Public API ---------------------------------------------------------------------------------------

M.analyzeRecipe = analyzeRecipe
M.refreshAnalysis = refreshAnalysis
M.analysisVersion = ANALYSIS_VERSION
M.startPersonalCertification = startPersonalCertification
M.getPersonalJobs = getPersonalJobs
M.processJobs = processJobs

-- Hooks --------------------------------------------------------------------------------------------

M.onUpdate = onUpdate
M.onCareerActivated = initialize
M.onOverhaulModulesActivated = initialize
M.onOverhaulSaveCurrentProfile = function(path)
  initialize()
  saveData(path)
end

return M
