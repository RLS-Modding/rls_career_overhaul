-- Owns work capabilities derived from loaner vehicle configurations and installed parts. Facilities choose the fleet; this module reads its capacity and equipment metadata to rank it.
-- Map: config/state, vehicle metadata, fleet capabilities, ranking, facility and employment queries.

local M = {}

-- Config ------------------------------------------------------------------------------------------
M.JOB_PARCEL = "parcel"
M.JOB_MATERIALS = "materials"
M.JOB_TRAILER = "trailer"
M.JOB_REPO = "repo"
M.JOB_VEHICLE = "vehicle"
local MATERIAL_CAPACITY_TYPES = {
  fluid = true,
  dryBulk = true,
  cement = true,
}
-- Generic company vehicles for shifts with no fleet truck; each entry's minimum org rep is in the data file.
local EMPLOYMENT_POOL_PATH = "/gameplay/overhaul/loaners/employmentPool.json"
local FIFTHWHEEL_UNLOCK_TAGS = {
  trailerDryvan = true,
  trailerTanker = true,
  trailerLogTrailer = true,
  trailerFlatbed = true,
  trailerContainer = true,
}

local MODEL_CLASS_PRIORITY = {
  van = 0,
  pickup = 1,
  md_series = 2,
  us_semi = 3,
}

-- State -------------------------------------------------------------------------------------------
local employmentPool
local profileCache = {}
local partsCache = {}

-- Shared helpers ----------------------------------------------------------------------------------
local function getEmploymentPool()
  if not employmentPool then
    local data = jsonReadFile(EMPLOYMENT_POOL_PATH)
    employmentPool = type(data) == "table" and type(data.vehicles) == "table" and data.vehicles or {}
  end
  return employmentPool
end

local function getConfigInfo(model, config)
  if not model or not config then return nil end
  return core_vehicles.getConfig(model, config)
end

local function isTrailerModel(configInfo, model)
  local aggregates = configInfo and configInfo.aggregates
  if aggregates and aggregates.Type and aggregates.Type.Trailer then return true end
  local modelInfo = model and core_vehicles.getModel(model)
  local modelData = modelInfo and (modelInfo.model or modelInfo)
  return modelData and modelData.Type == "Trailer" or false
end

local function getPartsTable(model, config, configInfo)
  local key = tostring(model or "") .. "\0" .. tostring(config or "")
  local cached = partsCache[key]
  if cached ~= nil then return cached or nil end
  configInfo = configInfo or getConfigInfo(model, config)
  local pcPath = configInfo and configInfo.pcFilename
  if not pcPath and model and config then pcPath = string.format("/vehicles/%s/%s.pc", model, config) end
  local data = pcPath and jsonReadFile(pcPath)
  local parts = type(data) == "table" and type(data.parts) == "table" and data.parts or nil
  partsCache[key] = parts or false
  return parts
end

-- Part names --------------------------------------------------------------------------------------
local function partNameLooksLikeCargoBox(partName)
  local p = string.lower(tostring(partName or ""))
  if p == "" then return false end
  return p:find("cargo_load_box", 1, true)
    or p:find("cargobox", 1, true)
    or p:find("van_cargo_load", 1, true)
    or p:find("cargo_load", 1, true) and not p:find("flatbed", 1, true)
end

local function partNameLooksLikeFlatbed(partName)
  local p = string.lower(tostring(partName or ""))
  if p == "" then return false end
  if p:find("cargobox", 1, true) then return false end
  -- Repo yards issue rollbacks/car carriers, not literal flatbed parts.
  return p:find("flatbed", 1, true) ~= nil or p:find("rollback", 1, true) ~= nil
    or p:find("tiltdeck", 1, true) ~= nil or p:find("carcarrier", 1, true) ~= nil
end

local function partNameLooksLikeFifthwheel(partName)
  local p = string.lower(tostring(partName or ""))
  if p == "" then return false end
  return p:find("fifthwheel", 1, true) or p:find("5th_wheel", 1, true) or p:find("kingpin", 1, true) ~= nil
end

local function partNameLooksLikeGooseneck(partName)
  local p = string.lower(tostring(partName or ""))
  if p == "" then return false end
  return p:find("gooseneck", 1, true) ~= nil
end

local function partNameLooksLikePintle(partName)
  local p = string.lower(tostring(partName or ""))
  if p == "" then return false end
  return p:find("pintle", 1, true) ~= nil
end

local function partNameLooksLikeTowHitch(partName)
  local p = string.lower(tostring(partName or ""))
  if p == "" then return false end
  if partNameLooksLikeGooseneck(p) or partNameLooksLikePintle(p) then return false end
  return p:find("towhitch", 1, true) ~= nil
    or p:find("tow_hitch", 1, true) ~= nil
    or p:find("receiver_ball", 1, true) ~= nil
    or p:find("receiver_drop", 1, true) ~= nil
end

local function partNameLooksLikeMaterialsBody(partName)
  local p = string.lower(tostring(partName or ""))
  if p == "" then return false end
  return p:find("tanker", 1, true)
    or p:find("dump", 1, true)
    or p:find("hopper", 1, true)
    or p:find("mixer", 1, true)
    or p:find("cement", 1, true)
end

local function partNameLooksLikeRollback(partName)
  local p = string.lower(tostring(partName or ""))
  if p == "" then return false end
  return p:find("rollback", 1, true) ~= nil or p:find("repo", 1, true) ~= nil
end

-- Profiles ----------------------------------------------------------------------------------------
local function ingestCapacityEntry(profile, cap)
  if type(cap) ~= "table" then return end
  local capType = cap.type
  local amount = tonumber(cap.amount) or 0
  if not capType or amount <= 0 then return end
  profile.capacityByType[capType] = math.max(profile.capacityByType[capType] or 0, amount)
  if require("overhaul/lib/logistics/cargoSemantics").cargo(capType).parcel then
    profile.hasCargoBoxes = true
    profile.parcelSlots = math.max(profile.parcelSlots or 0, amount)
  end
  if MATERIAL_CAPACITY_TYPES[capType] then profile.materialTypes[capType] = true end
end

local function newProfile(model, config, configInfo)
  return {
    model = model,
    config = config,
    capacityByType = {},
    materialTypes = {},
    parcelSlots = 0,
    hasCargoBoxes = false,
    hasFlatbed = false,
    hasFifthwheel = false,
    hasGooseneck = false,
    hasPintle = false,
    hasTowHitch = false,
    hasMaterialsBody = false,
    isTrailer = isTrailerModel(configInfo, model),
    isTractor = false,
  }
end

-- Sets the flags one part name implies; every part name is checked the same way.
local function markPartFlags(profile, partName)
  if partNameLooksLikeCargoBox(partName) then profile.hasCargoBoxes = true end
  if partNameLooksLikeFlatbed(partName) then profile.hasFlatbed = true end
  if partNameLooksLikeFifthwheel(partName) then profile.hasFifthwheel = true end
  if partNameLooksLikeGooseneck(partName) then profile.hasGooseneck = true end
  if partNameLooksLikePintle(partName) then profile.hasPintle = true end
  if partNameLooksLikeTowHitch(partName) then profile.hasTowHitch = true end
  if partNameLooksLikeMaterialsBody(partName) then profile.hasMaterialsBody = true end
end

-- Builds and caches what a configuration can do, from its capacities, its parts and its name.
local function buildProfile(model, config, offer)
  local key = tostring(model or "") .. "\0" .. tostring(config or "")
  if profileCache[key] then return profileCache[key] end

  local configInfo = getConfigInfo(model, config)
  local profile = newProfile(model, config, configInfo)
  for _, cap in ipairs((configInfo and configInfo.capacity) or {}) do
    ingestCapacityEntry(profile, cap)
  end

  local parts = getPartsTable(model, config, configInfo)
  if parts then
    for _, partName in pairs(parts) do
      markPartFlags(profile, partName)
    end
  end

  if not profile.hasFifthwheel and (partNameLooksLikeFifthwheel(config) or partNameLooksLikeFifthwheel(model)) then
    profile.hasFifthwheel = true
  end

  if offer and offer.vehOfferType == "trailer" then profile.isTrailer = true end

  profile.isTractor = profile.hasFlatbed
    or profile.hasFifthwheel
    or profile.hasGooseneck
    or profile.hasPintle
    or profile.hasTowHitch
    or (tostring(model or "") == "us_semi" and not profile.isTrailer)

  profileCache[key] = profile
  return profile
end

local function resolveOffer(offer)
  if type(offer) ~= "table" then return nil, nil, nil end
  return offer.model, offer.config, offer
end

function M.getProfile(offer)
  if type(offer) == "table" and offer.capacityByType then return offer end
  local model, config, item = resolveOffer(offer)
  if not model or not config then return nil end
  return buildProfile(model, config, item)
end

-- Capacity and body queries -----------------------------------------------------------------------
function M.getCapacity(offer, capacityType)
  local profile = M.getProfile(offer)
  if not profile or not capacityType then return 0 end
  return tonumber(profile.capacityByType[capacityType]) or 0
end

function M.getParcelSlots(offer)
  local profile = M.getProfile(offer)
  if not profile then return 0 end
  if profile.parcelSlots > 0 then return profile.parcelSlots end
  if profile.hasCargoBoxes then return math.huge end
  return 0
end

function M.isTractor(offer)
  local profile = M.getProfile(offer)
  return profile and profile.isTractor or false
end

function M.isTrailer(offer)
  local profile = M.getProfile(offer)
  return profile and profile.isTrailer or false
end

function M.canHaulMaterial(offer, cargoType, minAmount)
  if cargoType == "cash" then return M.canDoParcelJob(offer) end
  if not cargoType or not MATERIAL_CAPACITY_TYPES[cargoType] then return false end
  local profile = M.getProfile(offer)
  if not profile then return false end
  if profile.materialTypes[cargoType] then
    local amount = tonumber(profile.capacityByType[cargoType]) or 0
    minAmount = tonumber(minAmount)
    if minAmount and minAmount > 0 and amount > 0 and amount < minAmount then return false end
    return true
  end
  if profile.hasMaterialsBody and not next(profile.materialTypes) then
    -- Body style suggests materials gear but capacity metadata is missing.
    return true
  end
  return false
end

function M.canDoParcelJob(offer, minSlots)
  local profile = M.getProfile(offer)
  if not profile or profile.isTrailer then return false end
  if not profile.hasCargoBoxes and profile.parcelSlots <= 0 then return false end
  minSlots = tonumber(minSlots)
  if minSlots and minSlots > 0 and profile.parcelSlots > 0 and profile.parcelSlots < minSlots then return false end
  return true
end

function M.isMaterialsEquipment(offer)
  local profile = M.getProfile(offer)
  if not profile then return false end
  return next(profile.materialTypes) ~= nil or profile.hasMaterialsBody
end

-- Rollback and repo queries -----------------------------------------------------------------------
function M.canDoRollbackRepoJob(offer)
  local profile = M.getProfile(offer)
  if not profile or profile.isTrailer then return false end
  local config = string.lower(tostring((offer and offer.config) or profile.config or ""))
  if config:find("repo", 1, true) or config:find("rollback", 1, true) then return true end
  if profile.hasRollbackPart == nil then
    profile.hasRollbackPart = false
    for _, partName in pairs(getPartsTable(profile.model, profile.config) or {}) do
      if partNameLooksLikeRollback(partName) then
        profile.hasRollbackPart = true
        break
      end
    end
  end
  return profile.hasRollbackPart
end

function M.canDoTSeriesRollbackRepoJob(offer)
  local profile = M.getProfile(offer)
  return profile ~= nil and profile.model == "us_semi" and M.canDoRollbackRepoJob(offer)
end

function M.canDoRepoJob(offer)
  local profile = M.getProfile(offer)
  if not profile or profile.isTrailer then return false end
  if M.canDoRollbackRepoJob(offer) then return true end
  return profile.hasFlatbed == true
end

-- Coupler classes ---------------------------------------------------------------------------------
local function couplerClassFromText(text)
  local s = string.lower(tostring(text or ""))
  if s == "" then return nil end
  if s:find("gooseneck", 1, true) then return "gooseneck" end
  if s:find("pintle", 1, true) then return "pintle" end
  if s:find("fifthwheel", 1, true) or s:find("5th_wheel", 1, true) or s:find("kingpin", 1, true) then
    return "fifthwheel"
  end
  return nil
end

local function couplerClassFromFilter(filter)
  if type(filter) ~= "table" then return nil end
  local named = couplerClassFromText(filter.filterName) or couplerClassFromText(filter.id)
  if named then return named end
  local keys = filter.filter and filter.filter.whiteList and filter.filter.whiteList.key
  if type(keys) == "table" then
    for _, key in ipairs(keys) do
      named = couplerClassFromText(key)
      if named then return named end
    end
  elseif type(keys) == "string" then
    return couplerClassFromText(keys)
  end
  return nil
end

local function couplerClassFromTrailerParts(offer)
  local profile = M.getProfile(offer)
  if not profile then return nil end
  if profile.hasGooseneck then return "gooseneck" end
  if profile.hasFifthwheel then return "fifthwheel" end
  if profile.hasPintle then return "pintle" end
  if profile.hasTowHitch then return "towhitch" end
  return nil
end

function M.resolveTrailerCouplerClass(connector, unlockTag)
  local conn = type(connector) == "string" and string.lower(connector) or ""
  local tag = type(unlockTag) == "string" and unlockTag or ""
  if FIFTHWHEEL_UNLOCK_TAGS[tag] then return "fifthwheel" end
  if tag == "trailerDolly" then return "pintle" end
  if conn == "fifthwheel" or conn == "fifth_wheel" then return "fifthwheel" end
  if conn == "gooseneck" then return "gooseneck" end
  if conn == "pintle" then return "pintle" end
  return "towhitch"
end

function M.getOfferCouplerClass(offer)
  if not offer then return "towhitch" end
  local vehicle = offer.vehicle or {}
  local connector = offer.connector or vehicle.connector
  local unlockTag = offer.unlockTag or vehicle.unlockTag
  local filterId = vehicle.filterId or offer.filterId
  local filter
  if filterId then
    filter = require("overhaul/lib/logistics/templates").getVehicleFilterById(filterId)
    if filter then
      connector = connector or filter.connector
      unlockTag = unlockTag or filter.unlockTag
    end
  end
  if FIFTHWHEEL_UNLOCK_TAGS[unlockTag] then return "fifthwheel" end
  if unlockTag == "trailerDolly" then return "pintle" end

  local named = couplerClassFromText(offer.config or vehicle.config)
    or couplerClassFromText(offer.model or vehicle.model)
    or couplerClassFromFilter(filter)
    or couplerClassFromText(offer.name)
  if named then return named end

  local model = offer.model or vehicle.model
  local config = offer.config or vehicle.config
  if model and config then
    local fromParts = couplerClassFromTrailerParts({
      model = model,
      config = config,
      vehOfferType = offer.vehOfferType or vehicle.vehOfferType or "trailer",
    })
    if fromParts then return fromParts end
  end

  return M.resolveTrailerCouplerClass(connector, unlockTag)
end

function M.canTowTrailer(offer, opts)
  opts = opts or {}
  local profile = M.getProfile(offer)
  if not profile or profile.isTrailer then return false end
  local class = opts.couplerClass or M.resolveTrailerCouplerClass(opts.connector, opts.unlockTag)
  if class == "fifthwheel" then return profile.hasFifthwheel == true end
  if class == "gooseneck" then return profile.hasGooseneck == true end
  if class == "pintle" then return profile.hasPintle == true end
  return profile.hasTowHitch == true
end

local function materialsHaulCouplerClass(trailer)
  local named = M.getOfferCouplerClass(trailer)
  if named == "fifthwheel" or named == "gooseneck" then return named end
  local profile = M.getProfile(trailer)
  if not profile or not profile.isTrailer then return named end
  local model = tostring(profile.model or "")
  local haulsFluid = profile.materialTypes.fluid
    or (tonumber(profile.capacityByType.fluid) or 0) > 0
    or model == "tanker"
  if not haulsFluid then return named end
  if profile.hasTowHitch and not profile.hasFifthwheel and model ~= "tanker" then return "towhitch" end
  return "fifthwheel"
end

-- Fleet selection ---------------------------------------------------------------------------------
local function scoreCapacity(amount, targetLoad)
  amount = tonumber(amount) or 0
  targetLoad = tonumber(targetLoad)
  if targetLoad and targetLoad > 0 and amount > 0 then
    if amount < targetLoad then return -1 end
    return amount
  end
  return amount
end

local function collectFleetRepTiers(trucks, trailers)
  local tiers = {}
  local function add(item)
    local t = tonumber(item and item.reputationLvl)
    if t ~= nil then tiers[t] = true end
  end
  for _, item in ipairs(trucks or {}) do
    add(item)
  end
  for _, item in ipairs(trailers or {}) do
    add(item)
  end
  local sorted = {}
  for t in pairs(tiers) do
    table.insert(sorted, t)
  end
  table.sort(sorted)
  return sorted
end
-- Company employment issues the rig for your current org-rep band.
local function employmentAssignmentRepTier(playerRep, trucks, trailers)
  playerRep = tonumber(playerRep) or 0
  local sorted = collectFleetRepTiers(trucks, trailers)
  if not sorted[1] then return nil end

  for _, t in ipairs(sorted) do
    if t == playerRep then return t end
  end

  local band = nil
  for _, t in ipairs(sorted) do
    if t < playerRep then band = t end
  end
  return band
end

local function employmentPickRank(item)
  local rep = tonumber(item.reputationLvl) or -99
  local model = tostring(item and item.model or "")
  local classPri = MODEL_CLASS_PRIORITY[model] or 3
  return rep * 10 + classPri
end

local function pickBest(list, predicate, capacityFn, targetLoad, repAccessor, preferLowerRep)
  local bestItem, bestScore, bestRep, bestRank = nil, nil, nil, nil
  for _, item in ipairs(list or {}) do
    if item._unlocked ~= false and predicate(item) then
      local score = capacityFn and capacityFn(item) or 1
      if score >= 0 then
        local rep = repAccessor and repAccessor(item) or (tonumber(item.reputationLvl) or -99)
        local rank = preferLowerRep and employmentPickRank(item) or rep
        local repBetter
        if preferLowerRep then
          repBetter = not bestItem or rank < bestRank
        else
          repBetter = not bestItem or rep > bestRep
        end
        if
          not bestItem
          or (targetLoad and targetLoad > 0 and score >= targetLoad and (bestScore < targetLoad or score < bestScore))
          or (targetLoad and targetLoad > 0 and bestScore < targetLoad and score > bestScore)
          or ((not targetLoad or targetLoad <= 0 or bestScore < targetLoad) and repBetter)
        then
          bestItem, bestScore, bestRep, bestRank = item, score, rep, rank
        end
      end
    end
  end
  return bestItem
end

local function filterToRepTier(list, tier)
  if tier == nil then return list end
  local filtered = {}
  for _, item in ipairs(list or {}) do
    if tonumber(item.reputationLvl) == tier then table.insert(filtered, item) end
  end
  return filtered
end

local function nextRepTierAtOrBelow(playerRep, list)
  playerRep = tonumber(playerRep)
  if playerRep == nil then return nil end
  local best = nil
  for _, item in ipairs(list or {}) do
    if item._unlocked ~= false then
      local t = tonumber(item.reputationLvl)
      if t ~= nil and t <= playerRep then
        if not best or t > best then best = t end
      end
    end
  end
  return best
end
-- Rep tier used to rank offers; an offer without a tier ranks lowest.
local function repOf(item) return tonumber(item.reputationLvl) or -99 end

-- Keeps only the trucks and trailers at the employer's current rep band, unless the caller skips the band.
local function applyAssignmentBand(trucks, trailers, opts)
  if opts.skipAssignmentRepTier then return trucks, trailers end
  local playerRep = tonumber(opts.repLevel)
  local tierTrucks = trucks
  local tierTrailers = trailers
  if opts.assignmentTierFromLists then
    tierTrucks = opts.assignmentTierFromLists.trucks or trucks
    tierTrailers = opts.assignmentTierFromLists.trailers or trailers
  end
  return filterToRepTier(trucks, nextRepTierAtOrBelow(playerRep, tierTrucks)),
    filterToRepTier(trailers, nextRepTierAtOrBelow(playerRep, tierTrailers))
end

-- Within the rep band, prefer smaller entry rigs (van before pickup before semi).
local PREFER_LOWER_REP = true

local function selectParcelLoaner(trucks, targetLoad)
  local truck = pickBest(
    trucks,
    function(item) return M.canDoParcelJob(item, targetLoad) end,
    function(item) return scoreCapacity(M.getParcelSlots(item), targetLoad) end,
    targetLoad,
    repOf,
    PREFER_LOWER_REP
  )
  return truck, nil
end

local function selectRepoLoaner(trucks, opts)
  local repoFilter = opts.requireTSeriesRollback and M.canDoTSeriesRollbackRepoJob
    or opts.rollbackRepoOnly and M.canDoRollbackRepoJob
    or M.canDoRepoJob
  local truck = pickBest(trucks, function(item) return repoFilter(item) end, nil, nil, repOf, PREFER_LOWER_REP)
  return truck, nil
end

-- Distributor work issues the trailer's tow vehicle too; the trailer sets the coupling, not a tow hitch.
local function selectTrailerLoaners(trucks, trailers, opts)
  if opts.requireTrailer then
    local trailer = pickBest(trailers, M.isTrailer, nil, nil, repOf, PREFER_LOWER_REP)
    if not trailer then return nil, nil end
    local towOpts = { couplerClass = M.getOfferCouplerClass(trailer) }
    local truck = pickBest(
      trucks,
      function(item) return M.canTowTrailer(item, towOpts) end,
      nil,
      nil,
      repOf,
      PREFER_LOWER_REP
    )
    if not truck then return nil, nil end
    return truck, trailer
  end
  local couplerClass = opts.couplerClass or M.resolveTrailerCouplerClass(opts.connector, opts.unlockTag)
  local towOpts = { couplerClass = couplerClass }
  local truck = nil
  -- Prefer hitch trucks (pickups/vans) for bumper-pull trailers.
  if couplerClass == "towhitch" then
    truck = pickBest(trucks, function(item)
      local profile = M.getProfile(item)
      return profile and profile.hasTowHitch == true
    end, nil, nil, repOf, PREFER_LOWER_REP)
  end
  truck = truck
    or pickBest(trucks, function(item) return M.canTowTrailer(item, towOpts) end, nil, nil, repOf, PREFER_LOWER_REP)
  local trailer = pickBest(trailers, function(item) return M.isTrailer(item) end, nil, nil, repOf, PREFER_LOWER_REP)
  return truck, trailer
end

local function selectMaterialsLoaners(trucks, trailers, cargoType, targetLoad)
  local matCapFn = function(item) return scoreCapacity(M.getCapacity(item, cargoType), targetLoad) end
  local function isDedicatedMaterialsRig(item, minAmount)
    if not M.canHaulMaterial(item, cargoType, minAmount) then return false end
    if M.isTractor(item) and M.getCapacity(item, cargoType) <= 0 then return false end
    return true
  end

  local dedicated = pickBest(
    trucks,
    function(item) return isDedicatedMaterialsRig(item, targetLoad) end,
    matCapFn,
    targetLoad,
    repOf,
    PREFER_LOWER_REP
  )
  if dedicated then return dedicated, nil end

  local trailer = pickBest(
    trailers,
    function(item) return M.canHaulMaterial(item, cargoType, targetLoad) end,
    matCapFn,
    targetLoad,
    repOf,
    PREFER_LOWER_REP
  )
  if trailer then
    local towOpts = { couplerClass = materialsHaulCouplerClass(trailer) }
    local tractor = pickBest(
      trucks,
      function(item) return M.canTowTrailer(item, towOpts) end,
      nil,
      nil,
      repOf,
      PREFER_LOWER_REP
    )
    if tractor then return tractor, trailer end
  end

  dedicated = pickBest(
    trucks,
    function(item) return isDedicatedMaterialsRig(item, nil) end,
    function(item) return scoreCapacity(M.getCapacity(item, cargoType), nil) end,
    nil,
    repOf,
    PREFER_LOWER_REP
  )
  if dedicated then return dedicated, nil end

  return nil, nil
end

-- Picks the truck and trailer for one job kind from the employer's lists.
function M.selectCompanyLoaners(trucks, trailers, jobKind, opts)
  opts = opts or {}
  local targetLoad = tonumber(opts.targetLoad)
  trucks, trailers = applyAssignmentBand(trucks, trailers, opts)

  if jobKind == M.JOB_PARCEL then return selectParcelLoaner(trucks, targetLoad) end
  if jobKind == M.JOB_REPO then return selectRepoLoaner(trucks, opts) end
  if jobKind == M.JOB_VEHICLE then return nil, nil end
  if jobKind == M.JOB_TRAILER then return selectTrailerLoaners(trucks, trailers, opts) end
  if jobKind == M.JOB_MATERIALS then return selectMaterialsLoaners(trucks, trailers, opts.cargoType, targetLoad) end
  return nil, nil
end

-- Company loaner lists ----------------------------------------------------------------------------
-- Same careerSkills-logistics level employment uses for unlock sync.
function M.getPlayerLogisticsDeliveryLevel()
  local skillLookup = require("overhaul/lib/progression/skillLookup")
  if not skillLookup.hasBranchLevels() then return 0 end
  local best = skillLookup.maxPathLevel(0, { "careerSkills-logistics", "logistics" })
  if best > 0 then return math.floor(best) end
  if skillLookup.hasValueLevelsUncheckedCatalog() then
    local value = tonumber(skillLookup.attributeValue("logistics-delivery")) or 0
    local level = skillLookup.levelFromValue(value, "careerSkills-logistics")
    return math.max(0, math.floor(tonumber(level) or 0))
  end
  return 0
end

function M.prepareCompanyLoanerLists(offers, repLevel, deliveryLevel)
  repLevel = tonumber(repLevel) or 0
  if deliveryLevel == nil then deliveryLevel = M.getPlayerLogisticsDeliveryLevel() end
  deliveryLevel = tonumber(deliveryLevel) or 0
  local trucks, trailers = {}, {}
  for _, item in ipairs(offers or {}) do
    local copy = deepcopy(item)
    copy.loanType = "company"
    copy.enabled = true
    copy.disableReason = nil
    local reqRep = tonumber(copy.reputationLvl)
    local reqDel = tonumber(copy.deliveryLvl)
    local repOk = reqRep == nil or reqRep <= repLevel
    local delOk = reqDel == nil or reqDel <= deliveryLevel
    copy._unlocked = repOk and delOk
    if not delOk then
      copy.disableReason = string.format("Requires logistics level %s", tostring(reqDel))
    elseif not repOk then
      copy.disableReason = string.format("Requires company reputation %s", tostring(reqRep))
    end
    if M.isTrailer(copy) or copy.vehOfferType == "trailer" then
      table.insert(trailers, copy)
    else
      table.insert(trucks, copy)
    end
  end
  return trucks, trailers
end

local function getRepLevelForFacility(facility)
  if not facility or not facility.associatedOrganization then return 0 end
  local org = overhaul_world_organizations.getOrganization(facility.associatedOrganization)
  return tonumber(org and org.reputation and org.reputation.level) or 0
end

local function buildOffersFromOrganization(facility)
  if not facility or not facility.associatedOrganization then return {} end
  local org = overhaul_world_organizations.getOrganization(facility.associatedOrganization)
  local entries = facility.loanableVehicles or (org and org.loanableVehicles)
  if not entries then return {} end
  local offers = {}
  for index, rentalVehicleInfo in ipairs(entries) do
    table.insert(offers, {
      id = string.format(
        "employment-org-%s-%s-%s-%d",
        tostring(facility.id),
        tostring(rentalVehicleInfo.model),
        tostring(rentalVehicleInfo.config),
        index
      ),
      model = rentalVehicleInfo.model,
      config = rentalVehicleInfo.config,
      reputationLvl = rentalVehicleInfo.reputationLvl,
      deliveryLvl = rentalVehicleInfo.deliveryLvl,
      maxParcelPayloadKg = rentalVehicleInfo.maxParcelPayloadKg,
      requiredSkillLevel = rentalVehicleInfo.requiredSkillLevel,
      requiredPoliceLevel = rentalVehicleInfo.requiredPoliceLevel,
      sourceFacility = { type = "deliveryProvider", id = facility.id },
    })
  end
  return offers
end

local function normalizeCompanyOffers(offers)
  local normalized = {}
  for index, item in ipairs(offers or {}) do
    local copy = deepcopy(item)
    copy.enabled = true
    copy.disableReason = nil
    if not copy.id then
      local facId = copy.sourceFacility and copy.sourceFacility.id or "company"
      copy.id = string.format(
        "employment-%s-%s-%s-%d",
        tostring(facId),
        tostring(copy.model or "m"),
        tostring(copy.config or "c"),
        index
      )
    end
    table.insert(normalized, copy)
  end
  return normalized
end

local function buildEmploymentPoolOffers(facility, repLevel)
  repLevel = tonumber(repLevel) or 0
  local offers = {}
  local facId = facility and facility.id or "pool"
  for index, entry in ipairs(getEmploymentPool()) do
    local reqRep = tonumber(entry.reputationLvl) or -99
    if reqRep <= repLevel then
      table.insert(offers, {
        id = string.format(
          "employment-pool-%s-%s-%s-%d",
          tostring(facId),
          tostring(entry.model),
          tostring(entry.config),
          index
        ),
        model = entry.model,
        config = entry.config,
        reputationLvl = entry.reputationLvl,
        deliveryLvl = entry.deliveryLvl,
        sourceFacility = facility and { type = "deliveryProvider", id = facility.id } or nil,
        _fromEmploymentPool = true,
      })
    end
  end
  return offers
end

local function loanerPairReady(jobKind, truck, trailer)
  if jobKind == M.JOB_VEHICLE then return true end
  return truck ~= nil
end

local function orgFleetHasTowTractor(trucks, opts)
  for _, item in ipairs(trucks or {}) do
    if M.canTowTrailer(item, opts) then return true end
  end
  return false
end

local function orgFleetHasTowTractorAtRep(trucks, repLevel, opts)
  repLevel = tonumber(repLevel) or 0
  for _, item in ipairs(trucks or {}) do
    if M.canTowTrailer(item, opts) then
      local reqRep = tonumber(item.reputationLvl)
      if reqRep == nil or reqRep <= repLevel then return true end
    end
  end
  return false
end

function M.getServiceFleetForFacility(facility, repLevel)
  if not facility then return nil end
  local org = facility.associatedOrganization
      and overhaul_world_organizations.getOrganization(facility.associatedOrganization)
    or nil
  return require("overhaul/lib/logistics/serviceFleet").offers(facility, org, repLevel)
end

local function getFacilityLoanerLists(facility, repLevel)
  if not facility then return nil, nil end
  repLevel = repLevel ~= nil and tonumber(repLevel) or getRepLevelForFacility(facility)
  local serviceOffers, serviceFleet = M.getServiceFleetForFacility(facility, repLevel)
  if serviceOffers then return serviceOffers, {}, serviceFleet end
  -- Shared service organizations never lend to freight yards; explicit facility fleets still win.
  local org = facility.associatedOrganization
      and overhaul_world_organizations.getOrganization(facility.associatedOrganization)
    or nil
  if facility.loanableVehicles == nil and require("overhaul/lib/logistics/facilityRole").organization(org) then
    return {}, {}
  end
  local offers
  if overhaul_career_logistics_loanerVehicles then
    offers = overhaul_career_logistics_loanerVehicles.formatLoanerOfferForUi(facility)
  end
  if type(offers) ~= "table" or not offers[1] then offers = buildOffersFromOrganization(facility) end
  if type(offers) ~= "table" then return nil, nil end
  return M.prepareCompanyLoanerLists(normalizeCompanyOffers(offers), repLevel)
end

-- Company fleet for UI ----------------------------------------------------------------------------
local function filterByTest(items, test)
  local filtered = {}
  for _, item in ipairs(items) do
    if test(item) then filtered[#filtered + 1] = item end
  end
  return filtered
end

-- Tests whether a company vehicle can fill one of the required jobs: parcel, repo, trailer, distributor or material.
local function employmentVehicleTest(requiredKinds, trailers)
  local materialTrailers = {}
  for _, item in ipairs(trailers) do
    for cargoType in pairs(requiredKinds.materialTypes or {}) do
      if M.canHaulMaterial(item, cargoType) then
        materialTrailers[#materialTrailers + 1] = item
        break
      end
    end
  end
  return function(item)
    if requiredKinds.parcel and M.canDoParcelJob(item) then return true end
    if requiredKinds.repo and M.canDoRepoJob(item) then return true end
    if requiredKinds.trailer and not M.isTrailer(item) and M.isTractor(item) then return true end
    if requiredKinds.vehicle and requiredKinds.distributorHaul then
      if M.isTrailer(item) or M.isTractor(item) then return true end
    end
    for cargoType in pairs(requiredKinds.materialTypes or {}) do
      if M.canHaulMaterial(item, cargoType) then return true end
    end
    if not M.isTrailer(item) then
      for _, trailer in ipairs(materialTrailers) do
        if M.canTowTrailer(item, { couplerClass = M.getOfferCouplerClass(trailer) }) then return true end
      end
    end
    return false
  end
end

-- Keeps the trucks and trailers that fit the required jobs; also returns the test that decided it.
local function filterForRequiredKinds(trucks, trailers, requiredKinds)
  local isEmploymentVehicle = employmentVehicleTest(requiredKinds, trailers)
  return filterByTest(trucks, isEmploymentVehicle), filterByTest(trailers, isEmploymentVehicle), isEmploymentVehicle
end

-- True when the facility's own fleet cannot cover a required job, so the employment pool may fill in.
local function poolNeededFor(requiredKinds, trucks, trailers, repLevel)
  local function ownFleetMissing(jobKind, opts)
    opts = shallowcopy(opts or {})
    opts.repLevel = repLevel
    opts.skipAssignmentRepTier = true
    local truck, trailer = M.selectCompanyLoaners(trucks, trailers, jobKind, opts)
    return not loanerPairReady(jobKind, truck, trailer)
  end
  local showPool = requiredKinds.parcel and ownFleetMissing(M.JOB_PARCEL)
    or requiredKinds.trailer and ownFleetMissing(M.JOB_TRAILER)
    or requiredKinds.repo and ownFleetMissing(M.JOB_REPO, { rollbackRepoOnly = true })
  if not showPool then
    for cargoType in pairs(requiredKinds.materialTypes or {}) do
      if ownFleetMissing(M.JOB_MATERIALS, { cargoType = cargoType }) then
        showPool = true
        break
      end
    end
  end
  return showPool
end

-- Appends the employment pool's trucks and trailers, limited to the required jobs when there are any.
local function addEmploymentPool(
  trucks,
  trailers,
  facility,
  repLevel,
  deliveryLevel,
  requiredKinds,
  isEmploymentVehicle
)
  local poolTrucks, poolTrailers = M.prepareCompanyLoanerLists(
    normalizeCompanyOffers(buildEmploymentPoolOffers(facility, math.huge)),
    repLevel,
    deliveryLevel
  )
  for _, item in ipairs(poolTrucks or {}) do
    if type(requiredKinds) ~= "table" or isEmploymentVehicle(item) then trucks[#trucks + 1] = item end
  end
  for _, item in ipairs(poolTrailers or {}) do
    if type(requiredKinds) ~= "table" or isEmploymentVehicle(item) then trailers[#trailers + 1] = item end
  end
end

-- One UI row for a company vehicle: its display name, thumbnail and whether it can be taken now.
local function companyVehicleUiRow(item, vehicleType, serviceFleet)
  local configInfo = getConfigInfo(item.model, item.config)
  local name = item.name
    or (configInfo and (configInfo.loanerName or configInfo.Name))
    or item.config
    or item.model
    or "Company vehicle"
  name = core_locales.translateWithOrWithoutContext(name)
  if type(name) ~= "string" or name == "" then name = item.config or item.model or "Company vehicle" end
  return {
    id = item.id or string.format("%s-%s", tostring(item.model), tostring(item.config)),
    name = name,
    model = item.model,
    config = item.config,
    vehicleType = vehicleType,
    thumbnail = item.thumbnail or (configInfo and configInfo.preview) or "/ui/images/appDefault.png",
    available = item._unlocked ~= false,
    disableReason = item.disableReason,
    serviceUnlockLabel = item.serviceUnlockLabel,
    reputationLevel = tonumber(item.reputationLvl),
    logisticsLevel = not serviceFleet and tonumber(item.deliveryLvl) or nil,
    fromLoanerPool = item._fromEmploymentPool and true or false,
  }
end

-- UI rows for the trucks then the trailers, skipping any model and config already listed.
local function companyVehicleRows(trucks, trailers, serviceFleet)
  local rows = {}
  local seen = {}
  local function add(item, vehicleType)
    local key = tostring(item.model) .. "\0" .. tostring(item.config)
    if seen[key] then return end
    seen[key] = true
    rows[#rows + 1] = companyVehicleUiRow(item, vehicleType, serviceFleet)
  end
  for _, item in ipairs(trucks or {}) do
    add(item, "vehicle")
  end
  for _, item in ipairs(trailers or {}) do
    add(item, "trailer")
  end
  return rows
end

-- Own fleet first, then the pool; then by vehicle type, rep, logistics level and name.
local function sortCompanyVehicleRows(rows)
  table.sort(rows, function(leftOffer, rightOffer)
    if leftOffer.fromLoanerPool ~= rightOffer.fromLoanerPool then return not leftOffer.fromLoanerPool end
    if leftOffer.vehicleType ~= rightOffer.vehicleType then return leftOffer.vehicleType < rightOffer.vehicleType end
    local aRep, bRep = leftOffer.reputationLevel or -1, rightOffer.reputationLevel or -1
    if aRep ~= bRep then return aRep < bRep end
    local aLog, bLog = leftOffer.logisticsLevel or 0, rightOffer.logisticsLevel or 0
    if aLog ~= bLog then return aLog < bLog end
    return tostring(leftOffer.name) < tostring(rightOffer.name)
  end)
end

-- The company vehicles a facility offers the job board and the employment screen.
function M.getCompanyFleetForUi(facility, requiredKinds)
  if not facility then return {} end
  local repLevel = getRepLevelForFacility(facility)
  local deliveryLevel = M.getPlayerLogisticsDeliveryLevel()
  local trucks, trailers, serviceFleet = getFacilityLoanerLists(facility, repLevel)
  trucks = trucks or {}
  trailers = trailers or {}
  local isEmploymentVehicle
  if type(requiredKinds) == "table" then
    trucks, trailers, isEmploymentVehicle = filterForRequiredKinds(trucks, trailers, requiredKinds)
  end
  local poolAllowed = not serviceFleet
    and not (requiredKinds and requiredKinds.distributorHaul)
    and not (type(facility.loanableVehicles) == "table" and not facility.loanableVehicles[1])
  local showPool = poolAllowed and not (trucks[1] or trailers[1])
  if not showPool and poolAllowed and type(requiredKinds) == "table" then
    showPool = poolNeededFor(requiredKinds, trucks, trailers, repLevel)
  end
  if showPool then
    addEmploymentPool(trucks, trailers, facility, repLevel, deliveryLevel, requiredKinds, isEmploymentVehicle)
  end
  local rows = companyVehicleRows(trucks, trailers, serviceFleet)
  sortCompanyVehicleRows(rows)
  return rows
end

-- Issuing loaners ---------------------------------------------------------------------------------
function M.getIssuedLoanersForFacility(facility, jobKind, opts)
  if jobKind == M.JOB_VEHICLE then return nil, nil end
  opts = opts or {}
  -- Service facilities never borrow from the generic freight pool, even on replacement paths.
  if M.getServiceFleetForFacility(facility, opts.repLevel) then return nil, nil end
  if facility and facility.carHaulFacility and jobKind == M.JOB_TRAILER then
    opts = shallowcopy(opts)
    opts.requireTrailer = true
  end
  local repLevel = opts.repLevel ~= nil and tonumber(opts.repLevel) or getRepLevelForFacility(facility)
  opts.repLevel = repLevel
  local trucks, trailers = getFacilityLoanerLists(facility, repLevel)
  trucks = trucks or {}
  trailers = trailers or {}
  local truck, trailer = M.selectCompanyLoaners(trucks, trailers, jobKind, opts)
  if loanerPairReady(jobKind, truck, trailer) then return truck, trailer end

  local orgOpts = {}
  for key, value in pairs(opts) do
    orgOpts[key] = value
  end
  orgOpts.skipAssignmentRepTier = true
  truck, trailer = M.selectCompanyLoaners(trucks, trailers, jobKind, orgOpts)
  if loanerPairReady(jobKind, truck, trailer) then return truck, trailer end

  -- A distributor's authored fleet defines its hauling equipment and unlocks.
  if
    opts.requireTrailer
    or (facility and type(facility.loanableVehicles) == "table" and not facility.loanableVehicles[1])
  then
    return nil, nil
  end

  -- Trailer work waits for the org rep that unlocks its tow tractor instead of pool-injecting one.
  if
    jobKind == M.JOB_TRAILER
    and orgFleetHasTowTractor(trucks, opts)
    and not orgFleetHasTowTractorAtRep(trucks, repLevel, opts)
  then
    return nil, nil
  end

  local poolOffers = buildEmploymentPoolOffers(facility, repLevel)
  if not poolOffers[1] then return nil, nil end
  local poolTrucks, poolTrailers = M.prepareCompanyLoanerLists(normalizeCompanyOffers(poolOffers), repLevel)
  local poolOpts = {}
  for key, value in pairs(opts) do
    poolOpts[key] = value
  end
  poolOpts.skipAssignmentRepTier = true
  return M.selectCompanyLoaners(poolTrucks or {}, poolTrailers or {}, jobKind, poolOpts)
end

function M.canIssueLoanersForFacility(facility, jobKind, opts)
  if jobKind == M.JOB_VEHICLE then return true end
  local truck, trailer = M.getIssuedLoanersForFacility(facility, jobKind, opts)
  return loanerPairReady(jobKind, truck, trailer)
end

function M.canIssueTSeriesRollbackRepoForFacility(facility, opts)
  opts = shallowcopy(opts or {})
  opts.rollbackRepoOnly = true
  opts.requireTSeriesRollback = true
  return M.canIssueLoanersForFacility(facility, M.JOB_REPO, opts)
end

function M.canIssueRepoForFacility(facility, opts) return M.canIssueLoanersForFacility(facility, M.JOB_REPO, opts or {}) end
function M.getEmploymentAssignmentRepTier(facility, repLevel)
  repLevel = repLevel ~= nil and tonumber(repLevel) or getRepLevelForFacility(facility)
  local trucks, trailers = getFacilityLoanerLists(facility, repLevel)
  if not trucks then return nil end
  return employmentAssignmentRepTier(repLevel, trucks, trailers)
end

function M.getIssuedTruckForJob(facility, jobKind, cargoType, targetLoad)
  return M.getIssuedLoanersForFacility(facility, jobKind, {
    cargoType = cargoType,
    targetLoad = targetLoad,
  })
end

-- Roleplay vehicles -------------------------------------------------------------------------------
function M.selectRoleplayVehicle(trucks, trailers, opts)
  opts = opts or {}
  local rep = function(item) return tonumber(item.reputationLvl) or -99 end
  local playerRep = tonumber(opts.repLevel)
  local assignmentTier = employmentAssignmentRepTier(playerRep, trucks, trailers)
  if assignmentTier ~= nil then trucks = filterToRepTier(trucks, assignmentTier) end
  return pickBest(
    trucks,
    function(item) return item.enabled ~= false and item._unlocked ~= false end,
    nil,
    nil,
    rep,
    true
  )
end

function M.getRoleplayFleetForUi(facility)
  local repLevel = getRepLevelForFacility(facility)
  local trucks, serviceFleet = M.getServiceFleetForFacility(facility, repLevel)
  local result = {}
  for _, item in ipairs(trucks or {}) do
    local info = getConfigInfo(item.model, item.config)
    local available = item.enabled ~= false and item._unlocked ~= false
    result[#result + 1] = {
      model = item.model,
      config = item.config,
      name = item.name or (info and (info.loanerName or info.Name)) or item.model,
      thumbnail = item.thumbnail or (info and info.preview) or "/ui/images/appDefault.png",
      available = available,
      disableReason = item.disableReason,
      serviceUnlockLabel = item.serviceUnlockLabel,
      reputationLevel = tonumber(item.reputationLvl),
    }
  end
  table.sort(result, function(a, b)
    if a.available ~= b.available then return a.available end
    local aRep, bRep = a.reputationLevel or -1, b.reputationLevel or -1
    if aRep ~= bRep then return aRep < bRep end
    return tostring(a.name) < tostring(b.name)
  end)
  return result, serviceFleet and serviceFleet.unavailableReason or nil
end

function M.getIssuedRoleplayVehicleForFacility(facility, opts)
  opts = opts or {}
  local repLevel = opts.repLevel ~= nil and tonumber(opts.repLevel) or getRepLevelForFacility(facility)
  local offers = M.getServiceFleetForFacility(facility, repLevel)
  if not offers then return nil end
  local trucks = {}
  for _, offer in ipairs(offers) do
    if offer._unlocked and offer.enabled ~= false then trucks[#trucks + 1] = offer end
  end
  if opts.selection then
    for _, item in ipairs(trucks) do
      if
        item.model == opts.selection.model
        and item.config == opts.selection.config
        and item.enabled ~= false
        and item._unlocked ~= false
        and (tonumber(item.reputationLvl) or -99) <= repLevel
      then
        return item
      end
    end
    return nil
  end
  return M.selectRoleplayVehicle(trucks, {}, { repLevel = repLevel })
end

function M.canIssueRoleplayVehicleForFacility(facility, opts)
  return M.getIssuedRoleplayVehicleForFacility(facility, opts) ~= nil
end

-- Inventory checks --------------------------------------------------------------------------------
function M.inventoryVehAsOffer(vehInfo)
  if not vehInfo or not vehInfo.model then return nil end
  local config = vehInfo.config
  if type(config) == "table" then
    if config.partConfigFilename and path and path.splitWithoutExt then
      local _, configKey = path.splitWithoutExt(config.partConfigFilename)
      config = configKey
    else
      config = config.key or config.config
    end
  end
  if type(config) ~= "string" or config == "" then return nil end
  return { model = vehInfo.model, config = config }
end

function M.isInventoryTrailer(vehInfo, vehId)
  if vehInfo and vehInfo.model then
    local modelInfo = core_vehicles.getModel(vehInfo.model)
    local modelData = modelInfo and (modelInfo.model or modelInfo)
    if modelData and modelData.Type == "Trailer" then return true end
  end
  local obj = vehId and getObjectByID(vehId)
  if obj and obj.getField then
    local jbeam = obj:getField("JBeam", "0")
    if jbeam then
      local modelInfo = core_vehicles.getModel(jbeam)
      local modelData = modelInfo and (modelInfo.model or modelInfo)
      if modelData and modelData.Type == "Trailer" then return true end
    end
  end
  return false
end

function M.inventoryHasTrailer(vehicles)
  for _, entry in ipairs(vehicles or {}) do
    if M.isInventoryTrailer(entry.vehInfo, entry.vehId) then return true end
  end
  return false
end

function M.inventoryHasPowerUnit(vehicles)
  for _, entry in ipairs(vehicles or {}) do
    if entry.vehInfo and not M.isInventoryTrailer(entry.vehInfo, entry.vehId) then return true end
  end
  return false
end

function M.inventoryCanHaulMaterial(vehicles, cargoType, targetLoad)
  local trucks, trailers = {}, {}
  for _, entry in ipairs(vehicles or {}) do
    local vehInfo = entry.vehInfo or entry
    local offer = M.inventoryVehAsOffer(vehInfo)
    if offer then
      if M.isInventoryTrailer(vehInfo, entry.vehId) then
        trailers[#trailers + 1] = offer
      else
        trucks[#trucks + 1] = offer
      end
    end
  end
  local truck = M.selectCompanyLoaners(trucks, trailers, M.JOB_MATERIALS, {
    cargoType = cargoType,
    targetLoad = targetLoad,
    skipAssignmentRepTier = true,
  })
  return truck ~= nil
end

function M.inventoryHasTowTractor(vehicles, couplerClass)
  local towOpts = couplerClass and { couplerClass = couplerClass } or nil
  for _, entry in ipairs(vehicles or {}) do
    local offer = M.inventoryVehAsOffer(entry.vehInfo or entry)
    if offer and M.canTowTrailer(offer, towOpts) then return true end
  end
  return false
end

function M.inventoryHasRepoTruck(vehicles)
  for _, entry in ipairs(vehicles or {}) do
    local offer = M.inventoryVehAsOffer(entry.vehInfo or entry)
    if offer and M.canDoRepoJob(offer) then return true end
  end
  return false
end

function M.inventoryHasTSeriesRollbackRepoTruck(vehicles)
  for _, entry in ipairs(vehicles or {}) do
    local offer = M.inventoryVehAsOffer(entry.vehInfo or entry)
    if offer and M.canDoTSeriesRollbackRepoJob(offer) then return true end
  end
  return false
end

-- Reused equipment --------------------------------------------------------------------------------
local reusedEquipmentChecks = {
  trailer = function(couplerClass, equipmentRequest)
    return M.inventoryHasTowTractor(equipmentRequest.companyVehicles or equipmentRequest.issuedVehicles, couplerClass)
  end,
  repo = function(_, equipmentRequest) return M.inventoryHasRepoTruck(equipmentRequest.issuedVehicles) end,
  materials = function(_, equipmentRequest) return M.inventoryCanHaulMaterial(equipmentRequest.issuedVehicles, equipmentRequest.cargoType, equipmentRequest.targetLoad) end,
}

local function hasIssuedPowerUnit(_, equipmentRequest) return M.inventoryHasPowerUnit(equipmentRequest.issuedVehicles) end
for _, kind in ipairs({ "parcel", "police", "bus", "paramedic" }) do
  reusedEquipmentChecks[kind] = hasIssuedPowerUnit
end

function M.canReuseIssuedEquipmentForJob(jobKind, couplerClass, equipmentRequest)
  equipmentRequest = equipmentRequest or {}
  local issued = equipmentRequest.issuedVehicles
  if type(issued) ~= "table" or not issued[1] then return false end
  local check = reusedEquipmentChecks[jobKind]
  return not check or check(couplerClass, equipmentRequest)
end

-- Cache -------------------------------------------------------------------------------------------
function M.clearCache()
  profileCache = {}
  partsCache = {}
end

return M
