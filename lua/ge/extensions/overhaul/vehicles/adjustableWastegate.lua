-- Adds a live wastegate slider to fixed-wastegate turbos, either as a native boost variable or a software offset.
-- Map: Config, State, Turbo eligibility, Boost tune, Slot injection, Hooks, Game hooks; start at describeBoostTune.
local M = {}

local logTag = "adjustableWastegate"
local slotName = "rls_adjustable_wastegate"
local slotDescription = "Wastegate Actuator"
local PATCH_ID = "adjustableWastegate"
M.dependencies = {"overhaul_shell_patches"}

local INTERNAL_BOOST_VARS = {
  ["$rlsWastegateBase"] = true,
  ["$rlsWastegateLimitDelta"] = true,
}

local SOFTWARE_TUNE_MIN = -4
local SOFTWARE_TUNE_MAX = 7
local SOFTWARE_TUNE_STEP = 0.2

-- State -------------------------------------------------------------------------------------------

local previousGetPart
local rawPartCache = {}

-- Turbo eligibility -------------------------------------------------------------------------------

local function variablesDefineBoostControl(variables)
  if type(variables) ~= "table" then return false end

  for _, variable in ipairs(variables) do
    local variableName = type(variable) == "table" and variable[1] or nil
    if type(variableName) == "string" then
      local name = string.lower(variableName)
      if name:find("wastegate", 1, true) or name:find("boost", 1, true) then
        return true
      end
    end
  end
  return false
end

local function identifierMentionsWastegate(value)
  return type(value) == "string" and string.lower(value):find("wastegate", 1, true) ~= nil
end

local function identifiersMentionWastegate(values)
  if identifierMentionsWastegate(values) then return true end
  if type(values) ~= "table" then return false end

  for _, value in pairs(values) do
    if identifierMentionsWastegate(value) then return true end
  end
  return false
end

local function hasNativeWastegateSlot(part)
  if type(part) ~= "table" then return false end

  for _, slot in ipairs(part.slots2 or part.slots or {}) do
    if type(slot) == "table" then
      local name = slot.name or slot[1]
      local allowTypes = slot.allowTypes or slot[2]
      -- Skip the injected actuator slot so hooked getPart still counts as a fixed turbo.
      if name ~= slotName
          and (identifierMentionsWastegate(name) or identifiersMentionWastegate(allowTypes)) then
        return true
      end
    end
  end
  return false
end

local function hasNativeBoostControl(part, rawPart)
  if type(rawPart) == "table" then
    local rawTurbo = rawPart.turbocharger
    if type(rawTurbo) == "table" then
      for _, fieldName in ipairs({"wastegateStart", "wastegateLimit"}) do
        local value = rawTurbo[fieldName]
        if value ~= nil and tonumber(value) == nil then return true end
      end
    end
    if variablesDefineBoostControl(rawPart.variables) then return true end
  end

  return variablesDefineBoostControl(part.variables)
end

-- Reads the raw jbeam part once per file and part name; onFileChanged clears the cache.
local function rawHasNativeBoostControl(filename, partName)
  if type(filename) ~= "string" or filename == "" then return false end
  local cachedFile = rawPartCache[filename]
  if not cachedFile then cachedFile = {}; rawPartCache[filename] = cachedFile end
  if cachedFile[partName] == nil then
    local data = jsonReadFile(filename)
    cachedFile[partName] = hasNativeBoostControl({}, type(data) == "table" and data[partName] or nil)
  end
  return cachedFile[partName]
end

local function clearRawPartCache() rawPartCache = {} end

local function getFixedWastegateValues(turbo)
  if type(turbo) ~= "table" or type(turbo.wastegateStart) ~= "number" then return nil, nil end

  local limit = turbo.wastegateLimit
  if limit == nil then
    -- Same fallback turbocharger.lua uses when opening pressure is set but fully-open is omitted.
    limit = turbo.wastegateStart + 0.01
  elseif type(limit) ~= "number" then
    return nil, nil
  end

  return turbo.wastegateStart, limit
end

local function numericWastegateStart(turbo)
  if type(turbo) ~= "table" then return nil end
  local start = turbo.wastegateStart
  if type(start) == "number" then return start end
  if type(start) == "table" then return tonumber(start[1]) end
  return nil
end

local function isEligibleTurbo(partName, part, filename)
  if type(part) ~= "table" or type(part.turbocharger) ~= "table" then return false end

  local turbo = part.turbocharger
  local wastegateStart = getFixedWastegateValues(turbo)
  if wastegateStart == nil then return false end

  -- ECU/tune parts can also carry wastegate numbers; require the turbo hardware tables. maxExhaustPower is often still a "$=..." expression at getPart time, not a resolved number.
  local exhaustPower = turbo.maxExhaustPower
  if type(turbo.pressurePSI) ~= "table"
    or type(turbo.engineDef) ~= "table"
    or (type(exhaustPower) ~= "number" and (type(exhaustPower) ~= "string" or exhaustPower == "")) then
    return false
  end

  if hasNativeWastegateSlot(part) then return false end
  return not (hasNativeBoostControl(part) or rawHasNativeBoostControl(filename, partName))
end

-- Boost tune --------------------------------------------------------------------------------------

local function variableLooksLikeBoostControl(name, data)
  if INTERNAL_BOOST_VARS[name] then return false end
  if type(data) == "table" and data.hideInUI then return false end
  local haystack = string.lower(table.concat({
    tostring(name or ""),
    tostring(data and data.title or ""),
    tostring(data and data.name or ""),
  }, " "))
  return haystack:find("wastegate", 1, true) ~= nil or haystack:find("boost", 1, true) ~= nil
end

-- The main wastegate slider wins; per-mode reduce maps are never the target.
local function nativeBoostVariableScore(name, data)
  local key = string.lower(name or "")
  local title = string.lower(tostring(data.title or data.name or ""))
  if key == "$rlswastegateadjustment" then return 100 end
  -- Per-mode reduce maps ($wastegateStart1/2) are not the main target slider.
  if title:find("reduce", 1, true) or key:find("wastegatestart%d") then return 0 end
  if key == "$wastegatetarget" or title:find("wastegate target", 1, true) then return 50 end
  if key:find("wastegate", 1, true) or title:find("wastegate", 1, true) then return 40 end
  return 10
end

local function pickNativeBoostVariable(variables)
  if type(variables) ~= "table" then return nil, nil end

  local bestName, bestData, bestScore
  for name, data in pairs(variables) do
    if type(name) == "string" and type(data) == "table" and variableLooksLikeBoostControl(name, data) then
      if tonumber(data.min) and tonumber(data.max) then
        local score = nativeBoostVariableScore(name, data)
        if score > 0 and (not bestScore or score > bestScore) then
          bestName, bestData, bestScore = name, data, score
        end
      end
    end
  end
  return bestName, bestData
end

local function eachInstalledPartName(vehData, callback)
  local seen = {}
  local function consider(name)
    if type(name) == "string" and name ~= "" and not seen[name] then
      seen[name] = true
      callback(name)
    end
  end

  local config = vehData and vehData.config or {}
  local function visit(node)
    if type(node) ~= "table" then return end
    consider(node.chosenPartName or node.partName)
    for _, child in pairs(node.children or {}) do visit(child) end
  end
  visit(config.partsTree)
  for _, name in pairs(config.parts or {}) do consider(name) end
  for _, name in pairs(vehData and vehData.chosenParts or {}) do consider(name) end
end

local function softwareBoostTune(turbo)
  return {
    available = true,
    mode = "software",
    title = "Wastegate Adjustment",
    description = "Live wastegate offset on top of the current boost map, including drive modes.",
    unit = "psi",
    min = SOFTWARE_TUNE_MIN,
    max = SOFTWARE_TUNE_MAX,
    step = SOFTWARE_TUNE_STEP,
    baseline = 0,
    openingPressurePsi = numericWastegateStart(turbo),
  }
end

local function sliderFromVariable(varName, varData)
  return {
    available = true,
    mode = "native",
    varName = varName,
    title = varData.title or varData.name or "Boost",
    description = varData.description,
    unit = varData.unit or "psi",
    min = tonumber(varData.min),
    max = tonumber(varData.max),
    step = tonumber(varData.stepDis) or tonumber(varData.step) or 0.1,
    baseline = tonumber(varData.val) or tonumber(varData.default) or 0,
  }
end

-- Software tuning is offered only when an installed part is an eligible fixed-wastegate turbo.
local function hasEligibleInstalledTurbo(vehData, ioModule, ioCtx)
  local eligible = false
  eachInstalledPartName(vehData, function(partName)
    if eligible then return end
    local part, filename = ioModule.getPart(ioCtx, partName)
    if isEligibleTurbo(partName, part, filename) then
      eligible = true
    end
  end)
  return eligible
end

local function describeBoostTune(vehData)
  if type(vehData) ~= "table" then
    return { available = false }
  end

  local variables = vehData.vdata and vehData.vdata.variables
  local varName, varData = pickNativeBoostVariable(variables)
  if varName and varData then
    return sliderFromVariable(varName, varData)
  end

  local turbo = vehData.vdata and vehData.vdata.turbocharger
  if type(turbo) == "table" then
    return softwareBoostTune(turbo)
  end

  local ioModule = require("jbeam/io")
  local ioCtx = vehData.ioCtx
  if type(ioModule) ~= "table" or type(ioModule.getPart) ~= "function" or not ioCtx then
    return { available = false }
  end

  if not hasEligibleInstalledTurbo(vehData, ioModule, ioCtx) then
    return { available = false }
  end

  return softwareBoostTune(nil)
end

-- Slot injection ----------------------------------------------------------------------------------

local function hasInjectedSlot(part)
  for _, slot in ipairs(part.slots2 or {}) do
    if type(slot) == "table" and slot.name == slotName then return true end
  end
  return false
end

local function injectSlot(partName, part, filename)
  if hasInjectedSlot(part) or not isEligibleTurbo(partName, part, filename) then return false end

  local turbo = part.turbocharger
  local wastegateStart, wastegateLimit = getFixedWastegateValues(turbo)
  part.slots2 = part.slots2 or {}
  table.insert(part.slots2, {
    name = slotName,
    allowTypes = {slotName},
    denyTypes = {},
    default = "",
    description = slotDescription,
    variables = {
      ["$rlsWastegateBase"] = wastegateStart,
      ["$rlsWastegateLimitDelta"] = wastegateLimit - wastegateStart
    }
  })

  -- jbeam/io builds slotInfoUi before this hook; add it so the Career shop can name the slot.
  part.slotInfoUi = part.slotInfoUi or {}
  part.slotInfoUi[slotName] = part.slotInfoUi[slotName] or {
    name = slotName,
    allowTypes = {slotName},
    denyTypes = {},
    description = slotDescription
  }
  return true
end

local function hookedGetPart(ioCtx, partName)
  local part, filename = previousGetPart(ioCtx, partName)
  if part then injectSlot(partName, part, filename) end
  return part, filename
end

-- Patch install -----------------------------------------------------------------------------------

-- While Overhaul runs. jbeam/io decodes a fresh part table on every getPart, so no injected slot outlives the patch.
local function installHooks()
  overhaul_shell_patches.registerFields(PATCH_ID, function() return require("jbeam/io") end, {
    getPart = function(original)
      if type(original) ~= "function" then
        log("E", logTag, "jbeam/io API is unavailable")
        return
      end
      previousGetPart = original
      return hookedGetPart
    end,
  })
end

local function uninstallHooks()
  if overhaul_shell_patches then overhaul_shell_patches.unregister(PATCH_ID) end
  previousGetPart = nil
  rawPartCache = {}
end

-- Public API --------------------------------------------------------------------------------------

M.isEligibleTurbo = isEligibleTurbo
M.hasNativeBoostControl = hasNativeBoostControl
M.describeBoostTune = describeBoostTune

-- Game hooks --------------------------------------------------------------------------------------

M.onInit = function()
  setExtensionUnloadMode(M, "manual")
end
M.onExtensionLoaded = installHooks
M.onExtensionUnloaded = uninstallHooks
M.onFileChanged = function(filename)
  if type(filename) == "string" and filename:lower():match("%.jbeam$") then clearRawPartCache() end
end
M.onModActivated = clearRawPartCache
M.onModDeactivated = clearRawPartCache
M.onModManagerReady = clearRawPartCache
M.onClientEndMission = clearRawPartCache

return M
