-- Explicit service roles, historical data aliases and operator selection.
-- Read role normalization, facility/organization resolution, then operator selection.
local M = {}

local profiles = { bus = "bus", police = "police", paramedic = "paramedic", ambulance = "paramedic", emt = "paramedic" }

-- Read once from the owned service-yard data, then kept for the session.
local legacyData

local function normalize(value)
  if type(value) ~= 'string' then return nil end
  local role = profiles[value:lower()]
  if role then return role end
  -- New service yards use the kind's declared id; aliases remain for existing map data.
  return require('overhaul/lib/jobs/kinds').roleplayPois()[value] and value or nil
end

local function hasCargo(fac)
  if next(fac.logisticGenerators or {}) then return true end
  for _, key in ipairs({ "logisticTypesProvided", "logisticTypesReceived",
      "logisticTypesProvidedLookup", "logisticTypesReceivedLookup" }) do
    if next(fac[key] or {}) then return true end
  end
  return fac.vehicleDistributor == true or fac.carHaulFacility == true
end

-- Legacy role metadata stays with the owned service-yard data until map packs declare it directly.
local function aliases()
  if not legacyData then
    legacyData = jsonReadFile("/gameplay/overhaul/loaners/legacyServiceYards.json") or {}
  end
  return legacyData
end

local function legacyFacilityRole(facilityId)
  local mapId = getCurrentLevelIdentifier()
  if not mapId or type(facilityId) ~= "string" then return nil end
  for _, facility in ipairs(aliases().facilityRoles or {}) do
    if (not facility.mapId or facility.mapId == mapId) and facility.facilityId:lower() == facilityId:lower() then
      return normalize(facility.roleplayType)
    end
  end
end

function M.organization(org, organizationId)
  if not org then return nil end
  if org.roleplayType ~= nil then return normalize(org.roleplayType) end
  if org.employerType ~= nil then return normalize(org.employerType) end
  for _, alias in ipairs(aliases().organizationRoles or {}) do
    if alias.organizationId == (organizationId or org.id) and (not alias.mapId or alias.mapId == getCurrentLevelIdentifier()) then
      return normalize(alias.roleplayType)
    end
  end
end

function M.isPoliceOrganizationId(orgId)
  if type(orgId) ~= "string" then return false end
  local org = overhaul_world_organizations.getOrganization(orgId)
  return M.organization(org or {}, orgId) == "police"
end

function M.resolve(fac, org)
  if not fac then return nil end
  -- Explicit facility metadata wins, including false to opt out of a shared org.
  if fac.roleplayType ~= nil then return normalize(fac.roleplayType) end
  if fac.employerType ~= nil then return normalize(fac.employerType) end
  local legacyRole = legacyFacilityRole(fac.id)
  if legacyRole then return legacyRole end
  -- Never inherit a service role into a cargo/retail facility. Dedicated legacy service yards have no cargo generators; their organization remains a fallback.
  if hasCargo(fac) then return nil end
  return M.organization(org)
end

-- Route/config ownership is explicit. Loan owners must have a matching organization or yard role.
-- A map with several operators must bind the route/call, rather than take the first yard in the list.
function M.operator(role, loaningOrgs, binding, currentEmployer)
  binding = binding or {}
  if binding.organizationId ~= nil then
    return type(binding.organizationId) == "string" and binding.organizationId ~= "" and binding.organizationId or nil
  end
  local facilities = overhaul_world_facilities.getFacilitiesByType("deliveryProvider") or {}
  local function facilityOrg(fac)
    local id = fac.associatedOrganization
    local org = id and overhaul_world_organizations.getOrganization(id)
    return id and M.resolve(fac, org) == role and id or nil
  end
  if binding.facilityId then
    for _, fac in ipairs(facilities) do
      if fac.id == binding.facilityId then return facilityOrg(fac) end
    end
    return nil
  end
  if currentEmployer and currentEmployer.facilityId then
    for _, fac in ipairs(facilities) do
      if fac.id == currentEmployer.facilityId then return facilityOrg(fac) end
    end
  end
  local employerId = currentEmployer and currentEmployer.organizationId
  if employerId then
    if M.organization(overhaul_world_organizations.getOrganization(employerId) or {}, employerId) == role then return employerId end
    for _, fac in ipairs(facilities) do
      if fac.associatedOrganization == employerId and facilityOrg(fac) then return employerId end
    end
  end
  local owners = {}
  for id in pairs(loaningOrgs or {}) do owners[#owners + 1] = id end
  table.sort(owners)
  for _, id in ipairs(owners) do
    if M.organization(overhaul_world_organizations.getOrganization(id) or {}, id) == role then return id end
    for _, fac in ipairs(facilities) do
      if fac.associatedOrganization == id and facilityOrg(fac) then return id end
    end
  end
  local selected
  for _, fac in ipairs(facilities) do
    local id = facilityOrg(fac)
    if id then
      if selected and selected ~= id then return nil end
      selected = id
    end
  end
  return selected
end

return M
