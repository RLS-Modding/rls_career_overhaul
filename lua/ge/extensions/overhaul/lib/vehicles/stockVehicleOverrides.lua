-- Stock configs that the demolition derby and the loaner pools use, and the eligible-vehicle list with them added.
-- The game's own info files are not edited; these lists are the only place the configs are named.
-- Map: pool declarations, config overrides, independent lists, shared catalog views.
local M = {}

M.derbyPoolKey = "rlsDerby100"

-- Stock configs the demolition derby uses.
M.derbyConfigs = {
  barstow = {"awful"},
  bluebuck = {"horrible"},
  burnside = {"banger"},
  bx = {"derby_M"},
  covet = {"pointless"},
  fullsize = {"limo_derby", "miserable"},
  lansdale = {"25_derby_M", "33_derby_late_M"},
  legran = {"derby", "derby_wagon"},
  md_series = {"md_60_derbybus", "md_70_derbybus"},
  midsize = {"derby"},
  miramar = {"derby"},
  moonhawk = {"terrible"},
  nine = {"nine_junkrod"},
  pessima = {"derby"},
  pickup = {"d35_disappointment_A"},
  roamer = {"derby"},
  van = {"derby"},
  wendover = {"derby", "junkhana"},
}

-- Stock auxiliary loaner configs that stay in the vehicle pools as Loaner configs.
M.loanerConfigs = {
  us_semi = {"t83_base_shuffleboard", "tc82_base_shuffleboard", "tc83s_tanker_shuffleboard"},
}

-- "model/config" -> true for every config in a list.
local function lookup(list)
  local set = {}
  for model, configs in pairs(list) do
    for _, config in ipairs(configs) do
      set[model .. "/" .. config] = true
    end
  end
  return set
end

local derbySet = lookup(M.derbyConfigs)
local loanerSet = lookup(M.loanerConfigs)

local function setConfigType(info, configType)
  info["Config Type"] = configType
  info.aggregates = info.aggregates or {}
  info.aggregates["Config Type"] = {[configType] = true}
end

local function isCatalogEligible(source, allowLoadedTrailers)
  local types = source and source.aggregates and source.aggregates.Type
  return types and not types.Prop and not types.Utility and not types.PropParked and not types.PropTraffic
    and (allowLoadedTrailers or not source.hasLoad) and source.Value
end

-- Adds every stock loaner config that is missing from `list` and sellable; returns whether any was added.
local function appendMissingLoanerConfigs(list, allowLoadedTrailers, copyEntry)
  local present = {}
  for _, info in ipairs(list) do
    present[tostring(info.model_key) .. "/" .. tostring(info.key)] = true
  end
  local added = false
  for model, configs in pairs(M.loanerConfigs) do
    for _, config in ipairs(configs) do
      local source = not present[model .. "/" .. config] and core_vehicles.getConfig(model, config)
      if isCatalogEligible(source, allowLoadedTrailers) then
        local info = copyEntry(source)
        info.isAuxiliary = false
        setConfigType(info, "Loaner")
        info.Brand = info.aggregates.Brand and core_locales.translateWithPrefixFallback(next(info.aggregates.Brand), "ui.vehicleconfig.brand.") or ""
        table.insert(list, info)
        added = true
      end
    end
  end
  return added
end

function M.isDerbyConfig(model, config)
  return derbySet[tostring(model) .. "/" .. tostring(config)] == true
end

function M.isLoanerConfig(model, config)
  return loanerSet[tostring(model) .. "/" .. tostring(config)] == true
end

-- Gives the stock derby configs their derby pool Config Type.
function M.applyDerbyConfigType(list)
  for _, info in ipairs(list) do
    if M.isDerbyConfig(info.model_key, info.key) then
      setConfigType(info, M.derbyPoolKey)
    end
  end
  return list
end

-- getEligibleVehicles with the derby Config Types and the stock loaner configs added.
function M.getEligibleVehicles(allowAuxiliaryVehicles, allowLoadedTrailers)
  local list = util_configListGenerator.getEligibleVehicles(allowAuxiliaryVehicles, allowLoadedTrailers) or {}
  M.applyDerbyConfigType(list)
  if allowAuxiliaryVehicles then
    return list
  end
  if appendMissingLoanerConfigs(list, allowLoadedTrailers, deepcopy) then
    table.sort(list, function(a, b) return a.model_key .. a.key < b.model_key .. b.key end)
  end
  return list
end

local function copyCatalogEntry(source)
  local entry, aggregates = {}, {}
  for key, value in pairs(source) do entry[key] = value end
  for key, value in pairs(source.aggregates) do aggregates[key] = value end
  entry.aggregates = aggregates
  return entry
end

-- Filtering only reads nested metadata; copy the chosen config before changing it.
-- Separate row and aggregate maps keep pool overrides out of the engine catalog.
function M.getEligibleVehicleCatalog(allowAuxiliaryVehicles, allowLoadedTrailers)
  local list = {}
  for _, source in pairs(core_vehicles.getConfigList().configs) do
    if isCatalogEligible(source, allowLoadedTrailers)
        and (allowAuxiliaryVehicles or not source.isAuxiliary) then
      local entry = copyCatalogEntry(source)
      entry.Brand = entry.aggregates.Brand and core_locales.translateWithPrefixFallback(next(entry.aggregates.Brand), "ui.vehicleconfig.brand.") or ""
      list[#list + 1] = entry
    end
  end
  M.applyDerbyConfigType(list)
  if not allowAuxiliaryVehicles then
    appendMissingLoanerConfigs(list, allowLoadedTrailers, copyCatalogEntry)
  end
  table.sort(list, function(a, b) return a.model_key .. a.key < b.model_key .. b.key end)
  return list
end

return M
