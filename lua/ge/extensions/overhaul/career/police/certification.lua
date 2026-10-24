-- Police vehicle certification: charges the fee, tags the vehicle role and freezes the car until the player walks away.
-- The certification trigger sits on the police lot and only offers the role once police skill is high enough.
local M = {}

local skillLookup = require("overhaul/lib/progression/skillLookup")

local CERTIFIED_VEHICLE_RELEASE_DISTANCE = 25
local stations, stationTriggers, stationsLevelId = {}, {}, nil
local assignmentData = nil

local function loadStations(levelId, force)
  levelId = levelId or getCurrentLevelIdentifier()
  if not force and stationsLevelId == levelId then return stations end
  stations, stationTriggers, stationsLevelId = {}, {}, levelId
  if not levelId then return stations end
  for _, facility in ipairs(overhaul_world_facilities.getFacilitiesByType("roleCertification", levelId) or {}) do
    if type(facility.triggerName) == "string" and type(facility.role) == "string"
      and type(facility.skillPath) == "string" and type(facility.minimumLevel) == "number"
      and type(facility.fee) == "number" and facility.fee >= 0
      and type(facility.durationSeconds) == "number" and facility.durationSeconds >= 0
      and not stationTriggers[facility.triggerName] then
      stations[#stations + 1] = facility
      stationTriggers[facility.triggerName] = facility
    else
      log("W", "certification", "Ignoring invalid or duplicate certification station: " .. tostring(facility.id))
    end
  end
  if #stations == 0 then log("W", "certification", "No certification stations configured for " .. levelId) end
  return stations
end

-- Vehicle frozen after certification; released once the player drives away from it.
local certifiedVehicleId = nil

local function isPoliceCertificationUnlocked(station)
  station = station or assignmentData
  return station and skillLookup.levelFirstPathOrValue(station.skillAttributeKey or station.skillPath, station.skillPaths or {station.skillPath}) >= station.minimumLevel
end

local function notifyCertificationLocked()
  ui_message(string.format("%s requires skill level %d", assignmentData.name, assignmentData.minimumLevel), 8, "Certification", "info")
end

local function notifyCannotAffordCertification()
  ui_message("You do not have enough funds to certify your vehicle", 10, "error", "info")
end

local function getEffectiveCost()
  if not assignmentData then return 0 end
  local jobMarketIndex = overhaul_career_economy_globalEconomy.getJobMarketIndex() or 1.0
  return math.floor(assignmentData.cost * jobMarketIndex)
end

local function buildCertificationPrice()
  return {
    money = {amount = getEffectiveCost(), canBeNegative = false}
  }
end

local function canPay()
  if not assignmentData then return false end
  return overhaul_career_economy_payment.canPay(buildCertificationPrice())
end

-- The checkout operation records the fee as a service charge tagged with the role.
local function settleCertificationFee(inventoryId)
  local certificationPrice = buildCertificationPrice()
  local checkout = require("overhaul/lib/checkout/operations")
  local operation = checkout.begin("certification", {amount = certificationPrice.money.amount, target = {inventoryId = inventoryId, certificationId = assignmentData.id, levelId = assignmentData.levelId}})
  return checkout.settle(operation, function()
    return checkout.money.execute(overhaul_career_economy_payment.pay, certificationPrice, {
      category = "service", finance = {vehicleId = inventoryId, locationId = assignmentData.id},
      label = "Certification fee",
      tags = {"certification", assignmentData.role}
    })
  end)
end

-- Returns the UI to play, both when the certification prompt opens and when the player leaves the lot.
local function returnToPlayState()
  guihooks.trigger('ChangeState', {
    state = 'play',
    params = {}
  })
end

local function formatAssignRolePoi(station)
  local assignmentTrigger = scenetree.findObject(station.triggerName)
  local pos = assignmentTrigger and assignmentTrigger:getPosition() or nil
  if not pos then
    log("W", "certification", "Certification trigger unavailable: " .. station.triggerName)
    return nil
  end
  return {
    id = station.id,
    data = {type = "assignRole", facility = station},
    markerInfo = {
      bigmapMarker = {
        pos = pos,
        icon = "poi_fasttravel_round_orange_green",
        name = station.name,
        description = station.description or ("Certify your vehicle as a " .. station.role .. " vehicle"),
        previews = {station.preview},
        thumbnail = station.preview,
        cardIcon = "strobeLights",
      }
    }
  }
end

local function startCertification()
  if not assignmentData then return end
  returnToPlayState()
  if not isPoliceCertificationUnlocked() then
    notifyCertificationLocked()
    return
  end
  local inventoryId = overhaul_career_garage_inventory.getCurrentVehicle()
  if not inventoryId then return end

  -- A repeated call (double click, second confirm) must not charge again.
  if overhaul_career_garage_inventory.getVehicleRole(inventoryId) == assignmentData.role then
    ui_message("This vehicle is already certified.", 8, "Police", "info")
    return
  end
  if not canPay() then
    notifyCannotAffordCertification()
    return
  end
  if not settleCertificationFee(inventoryId) then
    notifyCannotAffordCertification()
    return
  end

  overhaul_career_garage_inventory.setVehicleRole(inventoryId, assignmentData.role)
  overhaul_career_garage_inventory.delayVehicleAccess(inventoryId, assignmentData.time, string.format("%s_certification", assignmentData.role))
  core_vehicleBridge.executeAction(be:getPlayerVehicle(0), 'setFreeze', true)
  -- Vehicle deletion can invalidate cached SimObjects.
  certifiedVehicleId = be:getPlayerVehicleID(0)
end

local function releaseCertifiedVehicle()
  overhaul_career_garage_inventory.removeVehicleObject(overhaul_career_garage_inventory.getInventoryIdFromVehicleId(certifiedVehicleId))
  certifiedVehicleId = nil
  require("overhaul/lib/save/store").request("certification:vehicleLeft")
end

local function onUpdate()
  if not certifiedVehicleId then return end
  local certifiedVehicle = getObjectByID(certifiedVehicleId)
  if not certifiedVehicle then
    certifiedVehicleId = nil
    return
  end
  local playerVehicle = be:getPlayerVehicle(0)
  if not playerVehicle then return end

  local vehiclePosition = certifiedVehicle:getPosition()
  local playerPosition = playerVehicle:getPosition()
  if (playerPosition - vehiclePosition):length() >= CERTIFIED_VEHICLE_RELEASE_DISTANCE then
    releaseCertifiedVehicle()
  end
end

local function requestAssignmentData()
  if not assignmentData then return assignmentData end
  local data = shallowcopy(assignmentData)
  data.baseCost = assignmentData.cost
  data.cost = getEffectiveCost()
  return data
end

M.canPay = canPay
M.startCertification = startCertification
M.requestAssignmentData = requestAssignmentData

-- Only an exact configured trigger can select a certification station.
local function onBeamNGTrigger(data)
  if data.subjectID ~= be:getPlayerVehicleID(0) or gameplay_walk.isWalking() then return end
  loadStations()
  local station = stationTriggers[data.triggerName]
  if not station then return end
  if data.event == "exit" then
    if assignmentData and assignmentData.id == station.id then
      assignmentData = nil
      returnToPlayState()
    end
    return
  end
  if data.event ~= "enter" then return end
  local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(data.subjectID)
  if not inventoryId then return end
  assignmentData = shallowcopy(station)
  assignmentData.levelId = getCurrentLevelIdentifier()
  assignmentData.time, assignmentData.cost, assignmentData.type = station.durationSeconds, station.fee, station.roleLabel or station.role
  if not isPoliceCertificationUnlocked() then
    notifyCertificationLocked()
    return
  end
  if overhaul_career_garage_inventory.getVehicleRole(inventoryId) ~= assignmentData.role then
    extensions.ui_router.navigate('roleAssignment')
  end
end

function M.onGetRawPoiListForLevel(levelIdentifier, elements)
  if not overhaul_career_career.isActive() then return end
  for _, station in ipairs(loadStations(levelIdentifier)) do
    if isPoliceCertificationUnlocked(station) then
      local poi = formatAssignRolePoi(station)
      if poi then table.insert(elements, poi) end
    end
  end
end

function M.onClientStartMission()
  assignmentData = nil
  loadStations(nil, true)
end

M.onBeamNGTrigger = onBeamNGTrigger
M.onUpdate = onUpdate

return M
