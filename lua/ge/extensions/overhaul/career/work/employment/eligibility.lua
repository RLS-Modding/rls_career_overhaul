-- Company logistics employment eligibility: unlock levels, skill gates, yard offers, employer and organization lookups.
-- Every method is late bound through the stable api table; yard kinds and level floors read the generator filters.
local skillLookup = require("overhaul/lib/progression/skillLookup")

local part = {}

local MATERIAL_WORK_LABELS = {
  fluid = "fluids",
  dryBulk = "aggregates",
  cement = "cement",
  cash = "cash",
}

local MATERIAL_ROWS = {
  { id = "fluid", label = "Fluids", flag = "logisticsFluidDelivery" },
  { id = "dryBulk", label = "Aggregates", flag = "logisticsAggregateDelivery" },
  { id = "cement", label = "Cement", flag = "logisticsCementDelivery" },
  { id = "cash", label = "Cash", flag = "logisticsCashDelivery" },
}

local ROLEPLAY_JOB_LABELS = {
  police = {"Police patrol", "Clock in and take a company vehicle"},
  bus = {"Bus routes", "Clock in and take a company bus"},
  paramedic = {"Paramedic calls", "Clock in and take a company ambulance"},
}

-- Helpers -------------------------------------------------------------------------------------------

-- Each work type this yard offers, with the level it needs.
local function listingKindLevels(api, fac, materialsUnlockFlags)
  local kindLevels = {}
  if api.facilityOffersKind(fac, "parcel") then
    table.insert(kindLevels, { kind = "Parcel runs", level = api.minParcelLevelForFacility(fac) })
  end
  if api.facilityOffersKind(fac, "trailer") then
    table.insert(kindLevels, {
      kind = "Trailer delivery",
      level = api.minTrailerLevelForFacility(fac),
    })
  end
  if api.facilityOffersKind(fac, "materials") then
    local matFlags = api.facilityMaterialUnlockFlags(fac)
    table.insert(kindLevels, {
      kind = "materials",
      level = api.minLevelForUnlockFlags(#matFlags > 0 and matFlags or materialsUnlockFlags),
    })
  end
  if api.facilityOffersKind(fac, "vehicle") then
    table.insert(kindLevels, {
      kind = "Car hauling",
      level = api.minVehicleLevelForFacility(fac),
    })
  end
  return kindLevels
end

-- The lowest required level among the yard's work types, and the kind that needs it.
local function lowestRequirement(kindLevels)
  local bestReq, bestKind = nil, nil
  for _, entry in ipairs(kindLevels) do
    local req = entry.level
    if req and (not bestReq or req < bestReq) then
      bestReq, bestKind = req, entry.kind
    end
  end
  return bestReq, bestKind
end

-- Every template in the generator's logistic types, skipping the employment-excluded types.
local function generatorTemplateCandidates(generator, templates, excluded)
  local candidates = {}
  for _, logisticType in ipairs(generator.logisticTypes or {}) do
    if not excluded[logisticType] then
      for _, template in ipairs(templates.getTemplatesByLogisticType(logisticType)) do
        table.insert(candidates, template)
      end
    end
  end
  return candidates
end

-- True when a parcel template fits the generator's slot range and carries no timed mods.
local function templateFitsGenerator(template, generator, excluded)
  local slots = tonumber(template.minSlots)
  return slots ~= nil and slots <= 128 and not template.materialType
    and (not generator.slotsMin or slots >= generator.slotsMin)
    and (not generator.slotsMax or (template.maxSlots or slots) <= generator.slotsMax)
    and not excluded[template.logisticType]
    and (tonumber((template.modChance or {}).timed) or 0) < 1
end

-- One parcel option: its slot count and the modifiers that always apply.
local function parcelOptionFromTemplate(template)
  local item = { slots = tonumber(template.minSlots), modifiers = {} }
  for key, chance in pairs(template.modChance or {}) do
    if chance >= 1 then table.insert(item.modifiers, { type = key }) end
  end
  return item
end

-- The unlock flag that gates a parcel slot tier.
local function slotTierFlag(slots)
  if slots > 64 then return "logisticsParcel128Slots" end
  if slots > 32 then return "logisticsParcel64Slots" end
  if slots > 16 then return "logisticsParcel32Slots" end
  return "smallPackagesDelivery"
end

-- Material types with no bulk flag are gated by their modifiers, read from the trainee table or the parcel mods.
local function materialModifierUnlocked(api, materialType)
  if api.usesTraineeUnlocks() then
    local parcelModifiers = api.sharedParcelMods()
    local modifiers = parcelModifiers and parcelModifiers.getModifiers()
    local unlockFlag = modifiers and modifiers[materialType] and modifiers[materialType].unlockFlag
    if unlockFlag then
      return api.hasUnlockFlag(unlockFlag)
    end
  end
  local mods = api.parcelMods()
  if not mods then return true end
  local locked = mods.lockedBecauseOfMods({[materialType] = true})
  return not locked
end

-- Joins sorted, de-duplicated labels; nil when there are none.
local function joinLabels(bits)
  table.sort(bits)
  return #bits > 0 and table.concat(bits, ", ") or nil
end

-- The lowest unlock level among the facility's generators of one type, or nil when none has one.
local function lowestGeneratorLevel(api, fac, generatorType)
  local best = nil
  for _, generator in ipairs(fac.logisticGenerators or {}) do
    if generator.type == generatorType and generator.filter and generator.offerMode ~= "independent" then
      for _, filterId in ipairs(type(generator.filter) == "table" and generator.filter or {generator.filter}) do
        local unlockFlag = api.filterUnlockFlag(filterId)
        local req = unlockFlag and api.getUnlockFlagMinLevels()[unlockFlag]
        if type(req) == "number" and (not best or req < best) then
          best = req
        end
      end
    end
  end
  return best
end

-- A distributor yard issues car hauling only; its other kinds come from the discovered offers.
local function addDistributorKinds(api, kinds, fac)
  if api.facilityOffersKind(fac, "vehicle") and api.hasUnlockFlag("logisticsCarHauling")
      and api.playerCanWorkJockeyAtFacility(fac) then
    kinds.vehicle = true
  end
end

local function addStandardKinds(api, materialTypeUnlockFlags, kinds, fac, caps)
  if api.facilityOffersKind(fac, "parcel") and api.playerCanWorkParcelsAtFacility(fac) then
    kinds.parcel = true
  end
  if api.facilityOffersKind(fac, "trailer") and api.playerCanWorkTrailerAtFacility(fac)
      and caps and caps.canIssueLoanersForFacility(fac, "trailer", {}) then
    kinds.trailer = true
  end
  if api.playerCanWorkMaterialsAtFacility(fac) and caps then
    local types = api.facilityMaterialTypes(fac)
    for matType in pairs(types) do
      local flag = materialTypeUnlockFlags[matType]
      if flag and api.hasUnlockFlag(flag)
          and caps.canIssueLoanersForFacility(fac, "materials", { cargoType = matType }) then
        kinds.materials = true
        break
      end
    end
  end
  -- Employment converts car-jockey yards into car hauling: company rollback + pickup backhaul. Rollback comes from the yard fleet or the RLS employment pool.
  if api.facilityOffersKind(fac, "vehicle") and api.playerCanWorkJockeyAtFacility(fac) then
    kinds.vehicle = true
    kinds.repo = true
  end
end

-- Appends one menu row; an unknown minimum level leaves the floor fields nil.
local function pushOffering(offerings, config, id, label, minLevel, available)
  table.insert(offerings, {
    id = id,
    label = label,
    minLevel = type(minLevel) == "number" and minLevel or nil,
    availableFromLevel = type(minLevel) == "number"
      and math.max(1, minLevel - config.EMPLOYEE_UNLOCK_LEVEL_OFFSET) or nil,
    available = available and true or false,
  })
end

-- Roleplay yards offer one job row; an add-on kind or the built-in service fleet supplies it.
local function roleplayOfferings(api, shared, push, offerings, facId, fac, profile, assignableKinds)
  local addon = api.discoveredOffer(facId, fac, profile)
  if addon then
    push(profile, addon.label, addon.minLevel, addon.available and assignableKinds[profile] == true)
    offerings[#offerings].unavailableReason = addon.unavailableReason
    return offerings
  end
  local caps = shared.loanerCapabilities()
  local available = caps and caps.canIssueRoleplayVehicleForFacility(fac, {})
  push(profile, api.makeRoleplayJob(profile).label, nil, available)
  local _, fleet
  if caps then _, fleet = caps.getServiceFleetForFacility(fac) end
  offerings[#offerings].unavailableReason = fleet and fleet.unavailableReason
  return offerings
end

local function addMaterialOfferings(api, push, fac, assignableKinds)
  for _, row in ipairs(MATERIAL_ROWS) do
    if api.facilitySupportsMaterialType(fac, row.id) then
      local minLevel = api.getUnlockFlagMinLevels()[row.flag]
      local available = assignableKinds.materials == true and api.hasUnlockFlag(row.flag)
      push(row.id, row.label, minLevel, available)
    end
  end
end

local function addStandardOfferings(api, push, fac, assignableKinds)
  if api.facilityOffersKind(fac, "trailer") then
    local trailerMin = api.minTrailerLevelForFacility(fac)
    local trailerAvailable = assignableKinds.trailer == true and api.playerCanWorkTrailerAtFacility(fac)
    push("trailer", "Trailer delivery", trailerMin, trailerAvailable)
  end

  if api.facilityOffersKind(fac, "parcel") then
    push(
      "parcel",
      "Parcel runs",
      api.minParcelLevelForFacility(fac),
      assignableKinds.parcel == true
    )
  end

  if api.facilityOffersKind(fac, "vehicle") then
    local minVehicle = api.isVehicleDistributorFacility(fac)
      and (api.getUnlockFlagMinLevels().logisticsCarHauling or 14)
      or api.minVehicleLevelForFacility(fac)
    push(
      "hauling",
      "Car hauling",
      minVehicle,
      assignableKinds.vehicle == true
    )
  end
end

-- Discovered kinds append after the built-in rows; a built-in row with the same id wins.
local function appendDiscoveredOfferings(api, offerings, push, facId, fac, assignableKinds)
  for _, offer in ipairs(api.discoveredMarketOffers(facId, fac) or {}) do
    local listed = false
    for _, row in ipairs(offerings) do
      if row.id == offer.id then listed = true; break end
    end
    if not listed then
      push(offer.id, offer.label, offer.minLevel, offer.available and assignableKinds[offer.id] == true)
      offerings[#offerings].unavailableReason = offer.unavailableReason
    end
  end
end

-- Whether a facility's fleet, jockey, logistics, and rollback signals make it a yard, and which kind.
local function classifyFromSignals(api, dropOff, org, fac)
  -- Delivery yards may attach local loaner overlays while the org table stays fleet-empty. Count either source.
  local hasFleet = api.orgHasFleet(org)
    or (type(fac.loanableVehicles) == "table" and fac.loanableVehicles[1] ~= nil)
  local hasJockey = api.facilityOffersKind(fac, "vehicle")
  local hasMaterials = api.facilityOffersKind(fac, "materials")
  local hasTrailer = api.facilityOffersKind(fac, "trailer")
  local hasParcel = api.facilityOffersKind(fac, "parcel")
  local hasLogistics = hasParcel or hasTrailer or hasMaterials
  local hasRollbackRepo = dropOff.facilityOffersRepo(fac.id)
  local isDistributor = api.isVehicleDistributorFacility(fac)

  -- New-vehicle distributors: jockeys + company fleet (truck/trailer multi-car) mix.
  if isDistributor then
    if hasJockey and hasFleet then return "jockey_mixed" end
    if hasJockey then return "jockey_only" end
    if hasFleet or hasLogistics then return "logistics" end
  end
  if hasJockey and hasRollbackRepo then
    return "jockey_repo_bundle"
  end
  if hasJockey and not hasFleet then
    return "jockey_only"
  end
  if hasJockey and hasFleet then
    return "jockey_mixed"
  end
  if hasLogistics then
    return "logistics"
  end
  return nil
end

-- Skill levels ------------------------------------------------------------------------------------

local function addSkillLevelApi(api, inputs)
  local lastSyncedDeliveryLevel = nil

  function api.getBranchLevelSafe(id)
    if not id or not skillLookup.hasBranchLevels() then return nil end
    -- Assign first; never tonumber(getBranchLevel()) because extra returns become tonumber's base.
    local level = skillLookup.branchLevel(id)
    if level == nil then return nil end
    return math.max(0, math.floor(tonumber(level) or 0))
  end

  function api.getDeliveryLevel()
    for _, id in ipairs(inputs.LOGISTICS_SKILL_PATH_IDS) do
      local level = api.getBranchLevelSafe(id)
      if level and level > 0 then return level end
    end
    for _, branch in ipairs(overhaul_career_progression_skills.getSortedBranches()) do
      if branch and not branch.missing and branch.isSkill and branch.attributeKey == inputs.LOGISTICS_ATTRIBUTE_KEY then
        local level = api.getBranchLevelSafe(branch.id or branch.pathId)
        if level and level > 0 then return level end
      end
    end
    if skillLookup.hasValueLevels() then
      local attrValue = skillLookup.attributeValue(inputs.LOGISTICS_ATTRIBUTE_KEY)
      local value = tonumber(attrValue) or 0
      for _, skillPathId in ipairs(inputs.LOGISTICS_SKILL_PATH_IDS) do
        local branchLevel = skillLookup.levelFromValue(value, skillPathId)
        local level = tonumber(branchLevel)
        if level and level > 0 then
          return math.max(0, math.floor(level))
        end
      end
    end
    return 0
  end

  function api.syncUnlockFlagsForDeliveryLevel()
    local level = api.getDeliveryLevel()
    if lastSyncedDeliveryLevel == level then return level end
    lastSyncedDeliveryLevel = level
    if overhaul_career_progression_unlockFlags then
      overhaul_career_progression_unlockFlags.resetFlags()
    end
    return level
  end

  function api.isApprenticeshipEnabled()
    local mode = overhaul_career_work_logisticsEmploymentMode
    if mode then
      return mode.isApprenticeshipEnabled()
    end
    return false
  end

  function api.isEmploymentUnlocked()
    return api.isApprenticeshipEnabled()
  end
end

-- Trainee flags follow the level table; other flags read the career's unlock flags ----------------

local function addUnlockFlagApi(api, inputs)
  local shared, config = inputs.shared, inputs.config

  local flagMinLevelByName = nil

  function api.getUnlockFlagMinLevels()
    if flagMinLevelByName then return flagMinLevelByName end
    flagMinLevelByName = {}
    local data = jsonReadFile("/gameplay/overhaul/domains/careerSkills/skills/logistics/info.json")
    if type(data) == "table" then
      for levelIdx, levelDef in ipairs(data.levels or {}) do
        for _, flag in ipairs(levelDef.unlockFlags or {}) do
          if type(flag) == "string" and flagMinLevelByName[flag] == nil then
            flagMinLevelByName[flag] = levelIdx
          end
        end
      end
    end
    return flagMinLevelByName
  end

  function api.usesTraineeUnlocks()
    return api.isApprenticeshipEnabled() and inputs.lifecycle.isEmployed()
  end

  function api.traineeHasUnlockFlag(flag)
    if type(flag) ~= "string" or flag == "" then return false end
    local req = api.getUnlockFlagMinLevels()[flag]
    if req == nil then
      return overhaul_career_progression_unlockFlags and overhaul_career_progression_unlockFlags.getFlag(flag) and true or false
    end
    return api.getDeliveryLevel() >= math.max(1, req - config.EMPLOYEE_UNLOCK_LEVEL_OFFSET)
  end

  function api.hasUnlockFlag(flag)
    if api.usesTraineeUnlocks() then
      return api.traineeHasUnlockFlag(flag)
    end
    return overhaul_career_progression_unlockFlags and overhaul_career_progression_unlockFlags.getFlag(flag) and true or false
  end

  function api.hasAnyUnlockFlag(flags)
    for _, flag in ipairs(flags or {}) do
      if api.hasUnlockFlag(flag) then return true end
    end
    return false
  end

  function api.playerKindUnlocked(kind)
    local policy = shared.kindPolicy(kind)
    if policy.parcels then return api.hasUnlockFlag("smallPackagesDelivery") end
    if policy.trailerDelivery then return api.hasAnyUnlockFlag(inputs.TRAILER_UNLOCK_FLAGS) end
    if policy.materialContract then return api.hasAnyUnlockFlag(inputs.MATERIALS_UNLOCK_FLAGS) end
    if policy.vehicleDelivery then return api.hasAnyUnlockFlag(inputs.VEHICLE_UNLOCK_FLAGS) end
    return false
  end

  function api.minLevelForUnlockFlags(flags)
    local mins = api.getUnlockFlagMinLevels()
    local best = nil
    for _, flag in ipairs(flags or {}) do
      local req = mins[flag]
      if type(req) == "number" and (not best or req < best) then
        best = req
      end
    end
    return best
  end
end

-- Shift and board access (the listing gate reports the skill requirement a yard shows) ------------

local function addShiftAccessApi(api, inputs)
  local state, shared, config = inputs.state, inputs.shared, inputs.config

  function api.getCurrentLevelLabel()
    local levelId = getCurrentLevelIdentifier()
    if not levelId or levelId == "" then return "this map" end
    local info = core_levels.getLevelByName(levelId)
    if info and info.title then
      return api.translateUiText(info.title, levelId)
    end
    return tostring(levelId)
  end

  function api.hasCompanyShift()
    return state.shift ~= nil
  end

  function api.getCargoBoardBlockMessage(_facId)
    if api.hasCompanyShift() then
      return "End your company shift before using the cargo board."
    end
    if api.isApprenticeshipEnabled() and api.getDeliveryLevel() < config.INDEPENDENT_CARGO_LEVEL then
      return "Reach Logistics level 30 for owner-operator cargo, or take company work from Employment."
    end
    return nil
  end

  function api.shouldShowFreelanceInspectAt(facId)
    if api.hasCompanyShift() then return false end
    if api.isRoleplayFacility(facId) then return false end
    if inputs.lifecycle.isEmployed() and inputs.dropOff.facilityMatchesEmployer(facId) then return false end
    if api.isApprenticeshipEnabled() and api.getDeliveryLevel() < config.INDEPENDENT_CARGO_LEVEL then
      return false
    end
    return true
  end

  function api.allowsOwnerOpYardBoard(facId)
    if not facId or api.hasCompanyShift() then return false end
    if not api.isApprenticeshipEnabled() then return false end
    if api.getDeliveryLevel() < config.INDEPENDENT_CARGO_LEVEL then return false end
    local gen = shared.generator()
    local fac = gen and gen.getFacilityById(facId)
    return api.isOwnerOpYardFacility(fac)
  end

  function api.getMapTravelBlockMessage()
    if not inputs.lifecycle.isOnShift() then return nil end
    return string.format("End your shift before leaving %s.", api.getCurrentLevelLabel())
  end

  function api.getActiveShiftOrgId()
    if state.shift and state.shift.shiftOrgId then
      return state.shift.shiftOrgId
    end
    return state.employerOrgId
  end

  function api.ensureDeliveryGenerator()
    if not shared.generator() then
      extensions.load("overhaul_career_logistics_generator")
    end
    return shared.generator()
  end

  function api.getListingSkillGate(facId, profile)
    local level = api.getDeliveryLevel()
    local gen = shared.generator()
    local fac = gen and gen.getFacilityById(facId)
    if not fac then
      return {
        skillLocked = true,
        requiredLevel = nil,
        skillMessage = "This yard is not available right now.",
      }
    end
    if shared.kindPolicy(profile).roleplay then
      return { skillLocked = false, requiredLevel = nil, skillMessage = nil }
    end

    local bestReq, bestKind = lowestRequirement(listingKindLevels(api, fac, inputs.MATERIALS_UNLOCK_FLAGS))
    if not bestReq then
      return {
        skillLocked = true,
        requiredLevel = nil,
        skillMessage = "No company work types are available at this yard yet.",
      }
    end
    if level >= bestReq then
      return { skillLocked = false, requiredLevel = bestReq, skillMessage = nil }
    end
    return {
      skillLocked = true,
      requiredLevel = bestReq,
      skillMessage = string.format(
        "Reach Logistics level %d for %s at this yard (you are L%d).",
        bestReq, bestKind or "this work", level
      ),
    }
  end

  -- Parcel unlocks (options come from yard templates, not the cargo board, so an empty board cannot hide a job) --

  function api.parcelMods()
    return overhaul_career_logistics_parcelMods
  end

  function api.sharedParcelMods()
    return require("overhaul/lib/logistics/parcelMods")
  end

  function api.maxUnlockedParcelSlots()
    if api.hasUnlockFlag("logisticsParcel128Slots") then return 128 end
    if api.hasUnlockFlag("logisticsParcel64Slots") then return 64 end
    if api.hasUnlockFlag("logisticsParcel32Slots") or api.hasUnlockFlag("largePackagesDelivery") then return 32 end
    return 16
  end

  function api.cargoItemUnlocked(item)
    local slots = math.floor((tonumber(item and item.slots) or 0) + 0.5)
    if slots > api.maxUnlockedParcelSlots() then return false end
    local parcelModifiers = api.sharedParcelMods()
    local modifierKeys = parcelModifiers.getModifierKeys(item)
    if not next(modifierKeys) then return true end
    if api.usesTraineeUnlocks() then
      local modifiers = parcelModifiers.getModifiers()
      if type(modifiers) == "table" then
        local flags = {}
        for key in pairs(modifierKeys) do
          local unlockFlag = modifiers[key] and modifiers[key].unlockFlag
          if unlockFlag then flags[unlockFlag] = api.hasUnlockFlag(unlockFlag) end
        end
        return not parcelModifiers.lockedBecauseOfMods(modifierKeys, flags, nil, modifiers)
      end
    end
    local mods = api.parcelMods()
    if not mods then return true end
    local locked = mods.lockedBecauseOfMods(modifierKeys)
    return not locked
  end
end

local function addCargoUnlockApi(api, inputs)
  local shared, MATERIAL_TYPE_UNLOCK_FLAGS = inputs.shared, inputs.MATERIAL_TYPE_UNLOCK_FLAGS

  -- Hiring must use the yard's configured boxes, rather than the generic parcel unlock. Inspect templates so a temporarily empty cargo board does not hide an unlocked job.
  function api.facilityParcelWorkOptions(fac)
    local options = {}
    if not fac then return options end
    local templates = require("overhaul/lib/logistics/templates")
    templates.loadParcelTemplates()
    local scanner = api.facilityScanner()
    for _, generator in ipairs(fac.logisticGenerators or {}) do
      if generator.type == "parcelProvider" then
        if generator.offerMode ~= "independent"
            and scanner.generatorProvidesParcels(generator, nil, inputs.EMPLOYMENT_PARCEL_EXCLUDED_TYPES) then
          for _, template in ipairs(generatorTemplateCandidates(generator, templates, inputs.EMPLOYMENT_PARCEL_EXCLUDED_TYPES)) do
            if templateFitsGenerator(template, generator, inputs.EMPLOYMENT_PARCEL_EXCLUDED_TYPES) then
              table.insert(options, parcelOptionFromTemplate(template))
            end
          end
        end
      end
    end
    return options
  end

  function api.playerCanWorkParcelsAtFacility(fac)
    if not api.playerKindUnlocked("parcel") then return false end
    local caps = shared.loanerCapabilities()
    if not caps then return false end
    for _, item in ipairs(api.facilityParcelWorkOptions(fac)) do
      if api.cargoItemUnlocked(item)
          and caps.canIssueLoanersForFacility(fac, "parcel", { targetLoad = item.slots }) then
        return true
      end
    end
    return false
  end

  function api.minParcelLevelForFacility(fac)
    local levels = api.getUnlockFlagMinLevels()
    local modifiers = api.sharedParcelMods().getModifiers()
    local best = nil
    for _, item in ipairs(api.facilityParcelWorkOptions(fac)) do
      local req = levels[slotTierFlag(item.slots)]
      if req then
        req = math.max(req, levels.smallPackagesDelivery or 1)
        for _, modifier in ipairs(item.modifiers) do
          local modFlag = modifiers[modifier.type] and modifiers[modifier.type].unlockFlag
          req = math.max(req, (modFlag and levels[modFlag]) or 1)
        end
        if not best or req < best then best = req end
      end
    end
    return best
  end

  -- Offer unlocks (material types resolve through their bulk type before the unlock flag is read) --

  function api.trailerOfferUnlocked(offer)
    local tag = offer and offer.vehicle and offer.vehicle.unlockTag
    local mgr = shared.vehicleOffers()
    if not tag or not mgr then return true end
    if api.usesTraineeUnlocks() then
      local unlockFlag = mgr.getVehicleTagUnlockFlag(tag)
      if unlockFlag then
        return api.hasUnlockFlag(unlockFlag)
      end
    end
    return mgr.isVehicleTagUnlocked(tag) and true or false
  end

  function api.vehicleOfferUnlocked(offer)
    return api.trailerOfferUnlocked(offer)
  end

  function api.materialOfferUnlocked(offer)
    if not offer then return false end
    local bulk = api.resolveMaterialBulkType(offer.materialType) or offer.cargoType
    local flag = bulk and MATERIAL_TYPE_UNLOCK_FLAGS[bulk]
    if flag then
      return api.hasUnlockFlag(flag)
    end
    local gen = shared.generator()
    if not gen then return true end
    local material = gen.getMaterialsTemplatesById(offer.materialType)
    if not material or not material.type then return false end
    return materialModifierUnlocked(api, material.type)
  end

  function api.resolveMaterialBulkType(materialTypeOrBulk)
    if not materialTypeOrBulk then return nil end
    if MATERIAL_TYPE_UNLOCK_FLAGS[materialTypeOrBulk] then
      return materialTypeOrBulk
    end
    local gen = shared.generator()
    local tpl = gen and gen.getMaterialsTemplatesById(materialTypeOrBulk)
    if tpl and tpl.type then return tpl.type end
    return require("overhaul/lib/logistics/templates").resolveMaterialBulkType(materialTypeOrBulk)
  end

  function api.facilityMaterialTypes(fac)
    return api.facilityScanner().facilityMaterialTypes(fac, api.resolveMaterialBulkType, MATERIAL_TYPE_UNLOCK_FLAGS, "employment")
  end

  function api.facilitySupportsMaterialType(fac, cargoType)
    return api.facilityScanner().facilitySupportsMaterialType(fac, cargoType, api.resolveMaterialBulkType, MATERIAL_TYPE_UNLOCK_FLAGS)
  end

  function api.playerCanWorkMaterialsAtFacility(fac)
    if not api.facilityOffersKind(fac, "materials") then return false end
    local types = api.facilityMaterialTypes(fac)
    if not next(types) then return false end
    for matType in pairs(types) do
      local flag = MATERIAL_TYPE_UNLOCK_FLAGS[matType]
      if flag and api.hasUnlockFlag(flag) then return true end
    end
    return false
  end

  function api.facilityMaterialUnlockFlags(fac)
    local flags = {}
    for matType, flag in pairs(MATERIAL_TYPE_UNLOCK_FLAGS) do
      if api.facilitySupportsMaterialType(fac, matType) then
        flags[#flags + 1] = flag
      end
    end
    return flags
  end

  function api.canIssueEmploymentMaterials(fac, cargoType)
    local caps = shared.loanerCapabilities()
    if not (fac and cargoType and caps) then return false end
    return caps.canIssueLoanersForFacility(fac, "materials", { cargoType = cargoType }) and true or false
  end

  function api.getIssuedEmploymentMaterials(fac, cargoType, targetLoad)
    local caps = shared.loanerCapabilities()
    if not (fac and cargoType and caps) then
      return nil, nil, { cargoType = cargoType, targetLoad = targetLoad }
    end
    local strictOpts = { cargoType = cargoType, targetLoad = targetLoad }
    local truck, trailer = caps.getIssuedLoanersForFacility(fac, "materials", strictOpts)
    if truck then return truck, trailer, strictOpts end
    local softOpts = { cargoType = cargoType }
    truck, trailer = caps.getIssuedLoanersForFacility(fac, "materials", softOpts)
    return truck, trailer, truck and softOpts or strictOpts
  end
end

-- Facility work (what a yard offers, and the work labels and level floors built from it) ----------

local function addFacilityWorkLabelsApi(api, inputs)
  local shared, MATERIAL_TYPE_UNLOCK_FLAGS = inputs.shared, inputs.MATERIAL_TYPE_UNLOCK_FLAGS

  function api.facilityScanner()
    return require("overhaul/lib/logistics/facilityScanner")
  end

  function api.uiLibrary()
    return require("overhaul/career/work/employment/ui")
  end

  function api.facilityOffersKind(fac, kind)
    return api.facilityScanner().facilityOffersKind(fac, kind, nil, "employment", inputs.EMPLOYMENT_PARCEL_EXCLUDED_TYPES)
  end

  function api.vehicleFilterUnlockTag(filterId)
    if not filterId then return nil end
    local tpl = require("overhaul/lib/logistics/templates")
    if not tpl then return nil end
    return tpl.getVehicleFilterUnlockTag(filterId)
  end

  -- Map a veh/trailer filter id to the careerSkills unlock flag (tags ≠ flags for some trailers).
  function api.filterUnlockFlag(filterId)
    local tag = api.vehicleFilterUnlockTag(filterId)
    if not tag then return nil end
    local mgr = shared.vehicleOffers()
    local flag = mgr and mgr.getVehicleTagUnlockFlag(tag)
    return flag or tag
  end

  function api.facilityHasLogisticsOffers(fac)
    return api.facilityOffersKind(fac, "parcel")
      or api.facilityOffersKind(fac, "trailer")
      or api.facilityOffersKind(fac, "materials")
  end

  function api.materialWorkLabel(fac)
    if not fac then return nil end
    local bits, seen = {}, {}
    for matType, label in pairs(MATERIAL_WORK_LABELS) do
      if api.facilitySupportsMaterialType(fac, matType) then
        local flag = MATERIAL_TYPE_UNLOCK_FLAGS[matType]
        if not flag or api.hasUnlockFlag(flag) then
          if not seen[label] then
            seen[label] = true
            table.insert(bits, label)
          end
        end
      end
    end
    return joinLabels(bits)
  end

  function api.trailerWorkLabel(fac)
    if not fac then return nil end
    local lookup = fac.logisticTypesProvidedLookup or {}
    local bits, seen = {}, {}
    for key, enabled in pairs(lookup) do
      if enabled and type(key) == "string" and key:find("^trailerDelivery", 1, true) then
        local label = "trailers"
        if key:find("Dryvan", 1, true) then label = "dry vans"
        elseif key:find("Container", 1, true) then label = "containers"
        elseif key:find("Flatbed", 1, true) then label = "flatbeds"
        elseif key:find("Residential", 1, true) then label = "household trailers"
        elseif key:find("Tanker", 1, true) then label = "tankers"
        elseif key:find("Log", 1, true) then label = "log trailers"
        end
        if not seen[label] then
          seen[label] = true
          table.insert(bits, label)
        end
      end
    end
    return joinLabels(bits)
  end

  function api.logisticsWorkLabel(fac, kinds)
    kinds = kinds or {}
    local bits = {}
    if kinds.parcel then table.insert(bits, "parcels") end
    local trailerLabel = kinds.trailer and api.trailerWorkLabel(fac) or nil
    if trailerLabel then table.insert(bits, trailerLabel) end
    local materialLabel = kinds.materials and api.materialWorkLabel(fac) or nil
    if materialLabel then table.insert(bits, materialLabel) end
    return #bits > 0 and table.concat(bits, ", ") or "assigned loads"
  end

  function api.minVehicleLevelForFacility(fac)
    if not fac then return api.minLevelForUnlockFlags(inputs.VEHICLE_UNLOCK_FLAGS) end
    local best = lowestGeneratorLevel(api, fac, "vehOfferProvider")
    if best then return best end
    return api.minLevelForUnlockFlags(inputs.VEHICLE_UNLOCK_FLAGS)
  end

  function api.minTrailerLevelForFacility(fac)
    if not fac then return api.minLevelForUnlockFlags(inputs.TRAILER_UNLOCK_FLAGS) end
    local best = lowestGeneratorLevel(api, fac, "trailerOfferProvider")
    if best then return best end
    return api.minLevelForUnlockFlags(inputs.TRAILER_UNLOCK_FLAGS)
  end

  -- Market kinds (job kinds a yard can issue, including add-on kinds found through marketOffering) --

  -- True when this yard generates at least one car-jockey tier the player has unlocked.
  function api.playerCanWorkJockeyAtFacility(fac)
    if not fac then return false end
    local sawTier = false
    for _, generator in ipairs(fac.logisticGenerators or {}) do
      if generator.type == "vehOfferProvider" and generator.filter and generator.offerMode ~= "independent" then
        for _,filterId in ipairs(type(generator.filter) == "table" and generator.filter or {generator.filter}) do
          local tag = api.vehicleFilterUnlockTag(filterId)
          local mgr = shared.vehicleOffers()
          if tag and mgr and mgr.isVehicleTagUnlocked
              and not mgr.getVehicleTagUnlockFlag(tag) and mgr.isVehicleTagUnlocked(tag) then
            return true
          end
          local unlockFlag = api.filterUnlockFlag(filterId)
          if unlockFlag then
            sawTier = true
            if api.hasUnlockFlag(unlockFlag) then
              return true
            end
          end
        end
      end
    end
    if sawTier then return false end
    return api.hasAnyUnlockFlag(inputs.VEHICLE_UNLOCK_FLAGS)
  end

  -- True when this yard generates at least one trailer tier the player has unlocked.
  function api.playerCanWorkTrailerAtFacility(fac)
    if not fac then return false end
    local sawTiers = false
    for _, generator in ipairs(fac.logisticGenerators or {}) do
      if generator.type == "trailerOfferProvider" and generator.filter and generator.offerMode ~= "independent" then
        for _,filterId in ipairs(type(generator.filter) == "table" and generator.filter or {generator.filter}) do
          local unlockFlag = api.filterUnlockFlag(filterId)
          if unlockFlag then
            sawTiers = true
            if api.hasUnlockFlag(unlockFlag) then
              return true
            end
          end
        end
      end
    end
    if sawTiers then return false end
    return api.playerKindUnlocked("trailer")
  end
end

local function addYardOfferingsApi(api, inputs)
  local shared, config, MATERIAL_TYPE_UNLOCK_FLAGS = inputs.shared, inputs.config, inputs.MATERIAL_TYPE_UNLOCK_FLAGS

  -- Registry-discovered job kinds list themselves through an optional marketOffering(ctx, facId) handler: nil hides the kind at that facility, otherwise {label, minLevel?, available, unavailableReason?}. Kinds without that handler or without an assignment builder are skipped, so shipped kinds (which have neither) keep their built-in rows and behaviour unchanged.
  function api.discoveredMarketOffers(facId, fac)
    local offers = {}
    for _, kind in ipairs(inputs.M.shiftKindDefinitions()) do
      local handlers = kind.handlers or {}
      if handlers.marketOffering and handlers.buildAssignment then
        local ctx = inputs.dispatch.dispatchContext()
        ctx.kind, ctx.facId, ctx.fac = deepcopy(kind), facId, fac
        local spec = shared.kindHandler(kind.id, "marketOffering", ctx, facId)
        if type(spec) == "table" and type(spec.label) == "string" and spec.label ~= "" then
          offers[#offers + 1] = {
            id = kind.id,
            label = spec.label,
            minLevel = type(spec.minLevel) == "number" and spec.minLevel or nil,
            available = spec.available == true,
            unavailableReason = type(spec.unavailableReason) == "string" and spec.unavailableReason or nil,
          }
        end
      end
    end
    return offers
  end

  -- The discovered offer for one kind id at this facility, available or not; nil when it is not listed here.
  function api.discoveredOffer(facId, fac, id)
    for _, offer in ipairs(api.discoveredMarketOffers(facId, fac) or {}) do
      if offer.id == id then return offer end
    end
    return nil
  end

  -- Adds each discovered kind whose marketOffering handler reports it available here.
  function api.addDiscoveredKinds(kinds, facId, fac)
    for _, offer in ipairs(api.discoveredMarketOffers(facId, fac) or {}) do
      if offer.available then kinds[offer.id] = true end
    end
    return kinds
  end

  function api.getAssignableKinds(facId)
    local kinds = {}
    local gen = shared.generator()
    local fac = gen and gen.getFacilityById(facId)
    if not fac then return kinds end
    local caps = shared.loanerCapabilities()
    if api.facilityIssuesDistributorHaul(fac) then
      addDistributorKinds(api, kinds, fac)
    else
      addStandardKinds(api, MATERIAL_TYPE_UNLOCK_FLAGS, kinds, fac, caps)
    end
    return api.addDiscoveredKinds(kinds, facId, fac) or kinds
  end

  function api.isParcelStringEmployer(facId)
    local kinds = api.getAssignableKinds(facId)
    if not kinds.parcel then return false end
    if kinds.trailer or kinds.materials or kinds.vehicle or kinds.repo then return false end
    return true
  end

  -- Offerings (built-in rows come first; a discovered kind never replaces a built-in row with the same id) --

  function api.offeringsWorkSummary(offerings)
    return api.uiLibrary().offeringsWorkSummary(offerings)
  end

  -- Full yard menu for employment UI: every work type this facility supports, with unlock floors. `available` mirrors getAssignableKinds (what hire-in would actually issue today).
  function api.buildFacilityOfferings(facId, profile, assignableKinds)
    local offerings = {}
    local gen = shared.generator()
    local fac = gen and gen.getFacilityById(facId)
    if not fac then return offerings end
    assignableKinds = assignableKinds or api.getAssignableKinds(facId)

    local function push(id, label, minLevel, available)
      pushOffering(offerings, config, id, label, minLevel, available)
    end

    if api.isRoleplayProfile(profile) then
      return roleplayOfferings(api, shared, push, offerings, facId, fac, profile, assignableKinds)
    end
    addMaterialOfferings(api, push, fac, assignableKinds)
    addStandardOfferings(api, push, fac, assignableKinds)
    appendDiscoveredOfferings(api, offerings, push, facId, fac, assignableKinds)
    return offerings
  end

  function api.workSummaryForProfile(profile, kinds, fac)
    kinds = kinds or {}
    local kind = shared.kindDefinition(profile)
    if kind and kind.workLabel then return kind.workLabel end
    local facId = fac and fac.id
    if facId then
      return api.offeringsWorkSummary(api.buildFacilityOfferings(facId, profile, kinds))
    end
    if profile == "logistics" then
      return api.logisticsWorkLabel(fac, kinds)
    end
    if profile == "jockey_only" then
      if kinds.parcel or kinds.trailer or kinds.materials then
        return api.logisticsWorkLabel(fac, kinds)
      end
      if kinds.repo or kinds.vehicle then
        return "Car hauling"
      end
      return "assigned loads"
    end
    if profile == "jockey_repo_bundle" then
      return "Car hauling"
    end
    if profile == "jockey_mixed" then
      local bits = {}
      if kinds.parcel then table.insert(bits, "Parcel runs") end
      local trailerLabel = kinds.trailer and api.trailerWorkLabel(fac) or nil
      if trailerLabel then table.insert(bits, trailerLabel) end
      local materialLabel = kinds.materials and api.materialWorkLabel(fac) or nil
      if materialLabel then table.insert(bits, materialLabel) end
      if api.playerKindUnlocked("vehicle") and (kinds.vehicle or kinds.repo) then
        table.insert(bits, "Car hauling")
      end
      return #bits > 0 and table.concat(bits, ", ") or "assigned loads"
    end
    return api.logisticsWorkLabel(fac, kinds)
  end

  -- Employers (roleplay yards are checked before logistics signals, so a service yard never reads as logistics) --

  function api.isRoleplayProfile(profile)
    return shared.kindPolicy(profile).roleplay
  end

  -- Employer profiles and service fleets -----------------------------------------------------------

  function api.getFacilityEmployerProfile(facId)
    local gen = shared.generator()
    local fac = gen and gen.getFacilityById(facId)
    if not fac or not fac.associatedOrganization then return nil, nil, nil end
    local org = api.getOrg(fac.associatedOrganization)
    if not org and overhaul_world_organizations then
      org = overhaul_world_organizations.getOrganization(fac.associatedOrganization)
    end
    return api.classifyEmployer(org, fac), org, fac
  end

  function api.isRoleplayFacility(facId)
    local gen = shared.generator()
    local fac = gen and gen.getFacilityById(facId)
    if not fac or not fac.associatedOrganization then return false end
    local org = api.getOrg(fac.associatedOrganization)
    if not org and overhaul_world_organizations then
      org = overhaul_world_organizations.getOrganization(fac.associatedOrganization)
    end
    return api.isRoleplayProfile(api.classifyRoleplayFacility(fac, org))
  end
end

local function addEmployerApi(api, inputs)
  local shared = inputs.shared

  function api.makeRoleplayJob(profile)
    local info = ROLEPLAY_JOB_LABELS[profile] or ROLEPLAY_JOB_LABELS.police
    return {
      kind = profile,
      label = info[1],
      subtext = info[2],
    }
  end

  function api.orgHasFleet(org)
    return org and type(org.loanableVehicles) == "table" and org.loanableVehicles[1] ~= nil
  end

  function api.classifyRoleplayOrg(org)
    return require('overhaul/lib/logistics/facilityRole').organization(org)
  end

  function api.classifyRoleplayFacility(fac, org)
    local profile = require('overhaul/lib/logistics/facilityRole').resolve(fac, org)
    if profile then return profile end
    if not fac or api.isOmittedFromEmployment(fac) then return nil end
    local named = type(fac.roleplayType) == 'string' and api.discoveredOffer(fac.id, fac, fac.roleplayType)
    if named and named.available and shared.kindPolicy(named.id).roleplay then return named.id end
  end

  function api.isOmittedFromEmployment(fac)
    return fac and fac.omitEmployment == true
  end

  function api.isVehicleDistributorFacility(fac)
    if not fac then return false end
    if fac.vehicleDistributor == false then return false end
    if api.isOmittedFromEmployment(fac) then return false end
    local org = api.getOrg(fac.associatedOrganization)
    if not org and fac.associatedOrganization and overhaul_world_organizations then
      org = overhaul_world_organizations.getOrganization(fac.associatedOrganization)
    end
    if api.classifyRoleplayFacility(fac, org) then return false end
    if fac.vehicleDistributor == true or fac.carHaulFacility == true then
      return true
    end
    if not api.facilityOffersKind(fac, "vehicle") then return false end
    if api.facilityOffersKind(fac, "parcel") then return false end
    if api.facilityOffersKind(fac, "trailer") then return false end
    if api.facilityOffersKind(fac, "materials") then return false end
    return true
  end

  function api.facilityIssuesDistributorHaul(fac)
    if not api.isVehicleDistributorFacility(fac) then return false end
    local caps = shared.loanerCapabilities()
    return caps and caps.canIssueLoanersForFacility(fac, "trailer", {}) or false
  end

  -- Owner-op / employment hubs: any logistics provider unless omitEmployment.
  function api.isOwnerOpYardFacility(fac)
    if not fac or api.isOmittedFromEmployment(fac) then return false end
    local org = api.getOrg(fac.associatedOrganization)
    if not org and fac.associatedOrganization and overhaul_world_organizations then
      org = overhaul_world_organizations.getOrganization(fac.associatedOrganization)
    end
    if api.classifyRoleplayFacility(fac, org) then return false end
    return api.facilityHasLogisticsOffers(fac) or api.isVehicleDistributorFacility(fac)
  end

  function api.classifyEmployer(org, fac)
    if not org or not fac then return nil end
    local roleplay = api.classifyRoleplayFacility(fac, org)
    if roleplay then return roleplay end
    if api.isOmittedFromEmployment(fac) then return nil end

    local profile = classifyFromSignals(api, inputs.dropOff, org, fac)
    if profile then return profile end
    -- Pure add-on yard: no built-in signal, but a discovered kind offers work here.
    for _, offer in ipairs(api.discoveredMarketOffers(fac.id, fac) or {}) do
      if offer.available then return "logistics" end
    end
    return nil
  end

  function api.canEmployAt(orgId, facId, previewOrg)
    local org = previewOrg or api.getOrg(orgId)
    if not org and orgId and overhaul_world_organizations then
      org = overhaul_world_organizations.getOrganization(orgId)
    end
    local gen = shared.generator()
    local fac = gen and gen.getFacilityById(facId)
    if not org or not fac or fac.associatedOrganization ~= orgId then
      return false, nil
    end
    if api.isOmittedFromEmployment(fac) then
      return false, nil
    end
    local profile = api.classifyEmployer(org, fac)
    if not profile then return false, nil end
    if shared.kindPolicy(profile).roleplay then
      local addon = api.discoveredOffer(facId, fac, profile)
      if addon then return addon.available, profile end
      local caps = shared.loanerCapabilities()
      local offers = caps and caps.getServiceFleetForFacility(fac)
      return offers ~= nil and offers[1] ~= nil, profile
    end
    -- Parcels / trailers / materials / jockey / repo — all require unlocked equipment + skill flags.
    return next(api.getAssignableKinds(facId)) ~= nil, profile
  end

  -- Organizations (the direct lookup runs first; the full organization table is only the fallback) --

  function api.getOrg(orgId)
    if not orgId or not overhaul_world_organizations then return nil end
    local ok, org = pcall(overhaul_world_organizations.getOrganization, orgId)
    if ok and org then return org end
    local all = overhaul_world_organizations.getOrganizations()
    if type(all) == "table" and all[orgId] then
      return all[orgId]
    end
    return nil
  end

  function api.getRepLevel(org)
    return tonumber(org and org.reputation and org.reputation.level) or 0
  end

  function api.translateUiText(value, fallback)
    return api.uiLibrary().translateText(value, fallback)
  end

  function api.getOrgDisplayName(org, orgId)
    return api.uiLibrary().orgDisplayName(org, orgId)
  end

  function api.getBusinessDisplayName(facId, orgId)
    if facId then
      local gen = shared.generator()
      local fac = gen and gen.getFacilityById(facId)
      if fac and fac.name then
        return api.translateUiText(fac.name, facId)
      end
    end
    return api.getOrgDisplayName(api.getOrg(orgId), orgId)
  end

  function api.getOrgReputationLabel(org, level)
    level = tonumber(level)
    if level == nil then level = api.getRepLevel(org) end
    return api.uiLibrary().reputationLabel(org, level)
  end
end

-- Constructor -------------------------------------------------------------------------------------

function part.new(inputs)
  local api = inputs.api or {}

  addSkillLevelApi(api, inputs)
  addUnlockFlagApi(api, inputs)
  addShiftAccessApi(api, inputs)
  addCargoUnlockApi(api, inputs)
  addFacilityWorkLabelsApi(api, inputs)
  addYardOfferingsApi(api, inputs)
  addEmployerApi(api, inputs)
  return api
end

return part
