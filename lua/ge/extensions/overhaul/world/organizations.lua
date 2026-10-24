-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/freeroam/organizations.lua (BeamNG 0.40).

local M = {}
local dataFiles = require("overhaul/lib/data/dataFiles")

local organizations

local blacklist = {
  ["/gameplay/organizations/logistics.organizations.json"] = true
}

local function addAdditionalInfoToOrg(organization)
  if overhaul_career_progression_reputation then
    overhaul_career_progression_reputation.addReputationToOrg(organization)
  end
  organization.visible = overhaul_career_career and overhaul_career_career.hasInteractedWithOrganization(organization.id)
  organization.attributeKey = organization.id.."Reputation"
end

local function loadOrganizations()
  if organizations then return false end

  -- init organizations table
  organizations = {}

  local files = {}
  for _, file in ipairs(dataFiles.findFiles("gameplay/organizations/", '*.organizations.json', -1, false, true)) do
    if not blacklist[file] then
      table.insert(files, file)
    end
  end
  for _,file in ipairs(files) do
    local data = jsonReadFile(file)
    for orgId, orgData in pairs(data) do
      orgData.id = orgId
      addAdditionalInfoToOrg(orgData)
      organizations[orgId] = orgData
    end
  end
  log("D","",string.format("Loaded organizations"))
  return true
end

local function getOrganizations()
  if not loadOrganizations() and overhaul_career_progression_reputation then
    for orgId, org in pairs(organizations) do
      addAdditionalInfoToOrg(org)
    end
  end
  return organizations
end

local function getOrganization(id)
  if id == nil or id == "" then return nil end
  local justLoaded = loadOrganizations()
  local organization = organizations and organizations[id]
  if organization then
    if not justLoaded and overhaul_career_progression_reputation then
      addAdditionalInfoToOrg(organization)
    end
    return organization
  else
    log("E","","Could not find organization with id " .. dumps(id))
  end
end

local function getOrganizationIdOrderAndIcon(id)
  return 7000, "peopleOutline" -- order of ids between 7000-8000
end

local function doesOrganizationOfferDeliveries(organization)
  for _, facility in ipairs(overhaul_world_facilities.getFacilitiesByType("deliveryProvider")) do
    if facility.associatedOrganization == organization.id then
      if facility.providedSystemsLookup and (facility.providedSystemsLookup.parcelDelivery or facility.providedSystemsLookup.vehicleDelivery) then
        return true
      end
    end
  end
end

local function orgHasUnlocks(organization)
  if not organization.reputationLevels or tableIsEmpty(organization.reputationLevels) then return false end
  local hasUnlocks = false
  for i, levelInfo in ipairs(organization.reputationLevels) do
    if levelInfo.unlocks and not tableIsEmpty(levelInfo.unlocks) then return true end
  end
  return false
end

local function getUIDataForOrg(orgId)
  local organization = deepcopy(getOrganization(orgId))
  if not organization then return end
  organization.reputation.max = overhaul_career_progression_reputation.getMaximumValue(organization)
  organization.reputation.min = overhaul_career_progression_reputation.getMinimumValue(organization)
  organization.reputation.label = overhaul_career_progression_reputation.getLabel(organization.reputation.level)
  organization.offersDeliveries = doesOrganizationOfferDeliveries(organization)
  organization.hasUnlocks = orgHasUnlocks(organization)
  organization.associatedFacilities = overhaul_career_career and overhaul_career_logistics_generator.getFacilitiesForOrganizationId(organization.id)

  for i, repLevelInfo in ipairs(organization.reputationLevels) do
    repLevelInfo.label = overhaul_career_progression_reputation.getLabel(i-2)
    repLevelInfo.level = i-2
  end
  return organization
end

local function getUIData()
  local result = {}
  for orgId, organization in pairs(getOrganizations()) do
    table.insert(result, getUIDataForOrg(orgId))
  end
  table.sort(result, function(a, b)
    return _tr(a.name) < _tr(b.name)
  end)
  return result
end

-- Loaded per level, like the game's module that is reloaded with every level.
M.onClientPreStartMission = function()
  organizations = nil
end

M.getOrganizations = getOrganizations
M.getOrganization = getOrganization
M.getOrganizationIdOrderAndIcon = getOrganizationIdOrderAndIcon
M.getUIData = getUIData
M.getUIDataForOrg = getUIDataForOrg
return M
