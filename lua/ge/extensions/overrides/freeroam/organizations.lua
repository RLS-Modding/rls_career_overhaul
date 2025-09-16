-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local organizations

local function addAdditionalInfoToOrg(organization)
  career_modules_reputation.addReputationToOrg(organization)
  organization.visible = career_career and career_career.hasInteractedWithOrganization(organization.id)
  organization.attributeKey = organization.id.."Reputation"
end

local function getOrganizations()
  if not organizations then

    -- init organizations table
    organizations = {}

    -- parse any other organization files inside the "/organizations" folder
    for _,file in ipairs(FS:findFiles("gameplay/organizations/", '*.organizations.json', -1, false, true)) do
      local data = jsonReadFile(file)
      for orgId, orgData in pairs(data) do
        orgData.id = orgId
        addAdditionalInfoToOrg(orgData)
        organizations[orgId] = orgData
      end
    end
    log("D","",string.format("Loaded organizations"))
  end
  return organizations
end

-- returns a single organization element.
local function getOrganization(id)
  local organizations = getOrganizations()
  local organization = organizations and organizations[id]
  if organization then
    addAdditionalInfoToOrg(organization)
    return organization
  else
    log("E","","Could not find organization with id " .. dumps(id))
  end
end

local function getOrganizationIdOrderAndIcon(id)
  return 7000, "peopleOutline" -- order of ids between 7000-8000
end

local function doesOrganizationOfferDeliveries(organization)
  for _, facility in ipairs(freeroam_facilities.getFacilitiesByType("deliveryProvider")) do
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
  organization.reputation.max = career_modules_reputation.getMaximumValue(organization)
  organization.reputation.min = career_modules_reputation.getMinimumValue(organization)
  organization.reputation.label = career_modules_reputation.getLabel(organization.reputation.level)
  organization.offersDeliveries = doesOrganizationOfferDeliveries(organization)
  organization.hasUnlocks = orgHasUnlocks(organization)
  organization.associatedFacilities = career_career and career_modules_delivery_generator.getFacilitiesForOrganizationId(organization.id)

  for i, repLevelInfo in ipairs(organization.reputationLevels) do
    repLevelInfo.label = career_modules_reputation.getLabel(i-2)
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
    return a.name < b.name
  end)
  return result
end

M.getOrganizations = getOrganizations
M.getOrganization = getOrganization
M.getOrganizationIdOrderAndIcon = getOrganizationIdOrderAndIcon
M.getUIData = getUIData
M.getUIDataForOrg = getUIDataForOrg
return M
