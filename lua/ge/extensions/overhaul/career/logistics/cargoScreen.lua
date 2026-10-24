-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/career/modules/delivery/cargoScreen.lua (BeamNG 0.40).
-- This owner keeps screen state and public hooks; cards, materials, request, commit and navigation own the work.
-- Read services and state, helpers, part construction, public operations, then lifecycle hooks.

local M = {}

local sharedCalc = require('overhaul/lib/logistics/calculators')
local cardsPart = require('overhaul/career/logistics/cargoScreen/cards')
local materialsPart = require('overhaul/career/logistics/cargoScreen/materials')
local requestPart = require('overhaul/career/logistics/cargoScreen/request')
local commitPart = require('overhaul/career/logistics/cargoScreen/commit')
local navigationPart = require('overhaul/career/logistics/cargoScreen/navigation')

M.dependencies = {"overhaul_shell_stepHandler"}

-- Config -----------------------------------------------------------------------------------------
local VEHICLE_SPAWN_TIMEOUT = 120

-- State ------------------------------------------------------------------------------------------

local ext = {
  parcelManager = nil,
  cargoScreen = nil,
  general = nil,
  generator = nil,
  progress = nil,
  vehicleOfferManager = nil,
  parcelMods = nil,
  vehicleTasks = nil,
  materialContracts = nil,
  step = nil,
}
-- The legacy board location remains unset because this fork dispatches to facility work owners.
local screen = {
  cardId = 0,
  cargoOverviewScreenOpen = false,
  cargoOverviewTab = "",
  cargoDataRequestSerial = 0,
  cargoOverviewLoanersOnly = false,
  cargoOverviewUiReady = false,
  cargoOverviewEnterToken = 0,
  visibleBigMapIdsToCardIds = {},
  pendingTransientMoves = false,
  materialPickupScreenOpen = false,
  materialPickupFacId = nil,
  materialPickupPsPath = nil,
  materialPickupContractId = nil,
  materialPickupLoadInProgress = false,
  cargoOverviewScreenOpenedTime = -1,
  cargoOverviewMaxTimeTimestamp = -1,
  sentNewCargoNotificationAlready = false,
  cargoScreenFacId = nil,
  cargoScreenPsPath = nil,
}

local vehicleSpawnInProgress = false
local vehicleSpawnStartedAt = nil
-- Shared helpers ---------------------------------------------------------------------------------
local function setVehicleSpawnInProgress(active)
  vehicleSpawnInProgress = active
  vehicleSpawnStartedAt = active and os.clockhp() or nil
end
-- A commit whose spawn or load callback never fires must not block the screen for the session.
local function isVehicleSpawnInProgress()
  if vehicleSpawnInProgress and vehicleSpawnStartedAt and os.clockhp() - vehicleSpawnStartedAt > VEHICLE_SPAWN_TIMEOUT then
    log("W", "cargoScreen", "Cargo commit vehicle spawn did not finish; releasing it")
    setVehicleSpawnInProgress(false)
  end
  return vehicleSpawnInProgress
end

local parts = {}

-- Every player-cargo marker stays visible when the tab filter changes.
local function setCargoScreenTab(tab)
  screen.cargoOverviewTab = tab
  local visibleIds = {}
  local idx = 1
  for bmId, data in pairs(screen.visibleBigMapIdsToCardIds) do
    for cardId, _ in pairs(data.cardIds) do
      local card = parts.cards.cardsById[cardId]
      if card.filterTags[tab] or card.filterTags['myCargo'] then
        visibleIds[idx] = bmId
        idx = idx + 1
        goto continue
      end
    end

    ::continue::
  end
  freeroam_bigMapMode.setOnlyIdsVisible(visibleIds)
  gameplay_rawPois.clear()
  freeroam_bigMapMarkers.clearMarkers()
  freeroam_bigMapMarkers.setNextMarkersFullAlphaInstant()
end

-- Parts ------------------------------------------------------------------------------------------
-- Preserve construction order while resolving the navigation cycle before the first UI request.
parts.cards = cardsPart.new({ext = ext, sharedCalc = sharedCalc})
parts.materials = materialsPart.new({
  ext = ext,
  screen = screen,
  addCard = parts.cards.addCard,
  getActiveOwnerOpContract = parts.cards.getActiveOwnerOpContract,
  ownerOpBlocksPerDiemOffer = parts.cards.ownerOpBlocksPerDiemOffer,
  OWNER_OP_PER_DIEM_BLOCK = parts.cards.OWNER_OP_PER_DIEM_BLOCK,
})
parts.request = requestPart.new({
  ext = ext,
  screen = screen,
  cardsById = parts.cards.cardsById,
  addCard = parts.cards.addCard,
  addActiveOwnerOpMyCargoCards = parts.cards.addActiveOwnerOpMyCargoCards,
  clusterFormatCargo = parts.cards.clusterFormatCargo,
  formatVehicleOfferForUi = parts.cards.formatVehicleOfferForUi,
  getAcceptedVehicleOffers = parts.cards.getAcceptedVehicleOffers,
  getActiveOwnerOpContract = parts.cards.getActiveOwnerOpContract,
  formatMaterialStorage = parts.materials.formatMaterialStorage,
  setCargoScreenTab = setCargoScreenTab,
})

parts.commit = commitPart.new({
  ext = ext,
  screen = screen,
  getActiveOwnerOpContract = parts.cards.getActiveOwnerOpContract,
  ownerOpBlocksPerDiemOffer = parts.cards.ownerOpBlocksPerDiemOffer,
  OWNER_OP_PER_DIEM_BLOCK = parts.cards.OWNER_OP_PER_DIEM_BLOCK,
  setVehicleSpawnInProgress = setVehicleSpawnInProgress,
})
parts.navigation = navigationPart.new({
  ext = ext,
  screen = screen,
  cardsById = parts.cards.cardsById,
  cancelDeliveryConfiguration = parts.commit.cancelDeliveryConfiguration,
  isVehicleSpawnInProgress = isVehicleSpawnInProgress,
  setMaterialContractPickupRoute = parts.materials.setMaterialContractPickupRoute,
})

parts.request.bindNavigation(parts.navigation)

-- Public API -------------------------------------------------------------------------------------
M.isCargoScreenOpen = function() return screen.cargoOverviewScreenOpen end
M.setCargoScreenTab = setCargoScreenTab
M.getCargoScreenTab = function() return screen.cargoOverviewTab end
M.getCargoScreenLocation = function()
  if not screen.cargoOverviewScreenOpen or not screen.cargoScreenFacId then return nil end
  return {facId = screen.cargoScreenFacId, psPath = screen.cargoScreenPsPath}
end

M.formatCargoGroup = parts.cards.formatCargoGroup
-- Keep the existing public entry point's no-op contract.
M.tryLoadAll = function(ids) end
M.formatAcceptedOfferForUI = parts.cards.formatAcceptedOfferForUI
M.abandonAcceptedOffer = function(vehId)
  extensions.hook("onGameplayActivityAborted")
  ext.vehicleTasks.giveBackDeliveryVehicle(vehId)
end


M.deliveryScreenExternalButtonPressed = function(id)
  local branchKey = "careerSkills"
  local branch = overhaul_career_progression_skills.getBranchById(branchKey)
  if not branch or branch.missing then
    branchKey = "labourer"
  end
  if id == "openDeliveryProgress" or id == "openVehicleDeliveryProgress" then
    extensions.ui_router.navigate('overhaul.branchPage', {pathId = 'careerSkills-logistics'})
  end
end

M.requestCargoDataForUi = parts.request.requestCargoDataForUi
M.onOverhaulCargoGenerated = parts.request.onOverhaulCargoGenerated

M.setMaterialContractPickupRoute = parts.materials.setMaterialContractPickupRoute
M.setMaterialContractDestinationRoute = parts.materials.setMaterialContractDestinationRoute
M.requestMaterialContractPickupData = parts.materials.requestMaterialContractPickupData
M.closeMaterialContractPickupScreen = parts.materials.closeMaterialContractPickupScreen
M.onMaterialContractPickupRouteLeave = function()
  screen.materialPickupScreenOpen = false
  screen.materialPickupFacId, screen.materialPickupPsPath, screen.materialPickupContractId = nil, nil, nil
  screen.materialPickupLoadInProgress = false
  simTimeAuthority.pause(false)
end
M.enterMaterialContractPickupScreen = parts.materials.enterMaterialContractPickupScreen
M.loadMaterialContract = parts.materials.loadMaterialContract

M.acceptMaterialContract = function(contractId)
  local accepted = ext.materialContracts and ext.materialContracts.acceptContract(contractId) or false
  if accepted then
    local active = ext.materialContracts.getContractById(contractId)
    local atPickup = active and active.origin and active.origin.facId == screen.cargoScreenFacId and active.origin.psPath == screen.cargoScreenPsPath
    parts.navigation.exitCargoOverviewScreen()
    if atPickup then
      parts.materials.enterMaterialContractPickupScreen(active.id, active.origin.facId, active.origin.psPath)
    else
      parts.materials.setMaterialContractPickupRoute(active.id, false)
    end
  end
  if screen.cargoOverviewScreenOpen then
    parts.request.requestCargoDataForUi(screen.cargoScreenFacId, screen.cargoScreenPsPath, false)
  end
  return accepted
end

M.abandonMaterialContract = function(contractId)
  local abandoned = ext.materialContracts and ext.materialContracts.abandonContract(contractId) or false
  if screen.cargoOverviewScreenOpen then
    parts.request.requestCargoDataForUi(screen.cargoScreenFacId, screen.cargoScreenPsPath, false)
  end
  return abandoned
end

M.enterPassiveBusinessSupplyPickupScreen = function(facId, psPath)
  local module = overhaul_career_business_passive
  parts.navigation.exitCargoOverviewScreen()
  return module and module.enterSupplyPickupScreen and module.enterSupplyPickupScreen(facId, psPath) or false
end
M.requestPassiveBusinessSupplyPickupData = function()
  local module = overhaul_career_business_passive
  return module and module.requestSupplyPickupData and module.requestSupplyPickupData() or false
end
M.loadPassiveBusinessSupply = function(quantity)
  local module = overhaul_career_business_passive
  return module and module.loadSupply and module.loadSupply(quantity) or false
end
M.closePassiveBusinessSupplyPickupScreen = function()
  local module = overhaul_career_business_passive
  return module and module.closeSupplyPickupScreen and module.closeSupplyPickupScreen() or false
end
M.onPassiveBusinessSupplyPickupRouteLeave = function()
  local module = overhaul_career_business_passive
  return module and module.onSupplyPickupRouteLeave and module.onSupplyPickupRouteLeave() or false
end
M.enterEngineShopSupplyPickupScreen = function(facId, psPath)
  local module = overhaul_career_business_engineShop
  parts.navigation.exitCargoOverviewScreen()
  return module and module.enterSupplyPickupScreen and module.enterSupplyPickupScreen(facId, psPath) or false
end
M.requestEngineShopSupplyPickupData = function()
  local module = overhaul_career_business_engineShop
  return module and module.requestSupplyPickupData and module.requestSupplyPickupData() or false
end
M.loadEngineShopSupply = function(quantity)
  local module = overhaul_career_business_engineShop
  return module and module.loadSupply and module.loadSupply(quantity) or false
end
M.closeEngineShopSupplyPickupScreen = function()
  local module = overhaul_career_business_engineShop
  return module and module.closeSupplyPickupScreen and module.closeSupplyPickupScreen() or false
end

M.applyTransientMoves = function()
  extensions.hook("onGameplayActivityAborted")
  ext.parcelManager.applyTransientMoves()
end

M.spawnOffer = function(...) return ext.vehicleOfferManager.spawnOffer(...) end

M.toggleOfferForSpawning = parts.materials.toggleOfferForSpawning
M.moveCargoFromUi = parts.materials.moveCargoFromUi
M.enterMyCargo = parts.navigation.enterMyCargo

-- Career lifecycle ------------------------------------------------------------------------------
M.onCareerActivated = function()
  ext.parcelManager = overhaul_career_logistics_parcelManager
  ext.cargoScreen = overhaul_career_logistics_cargoScreen
  ext.general = overhaul_career_logistics_general
  ext.generator = overhaul_career_logistics_generator
  ext.progress = overhaul_career_logistics_progress
  ext.vehicleOfferManager = overhaul_career_logistics_vehicleOfferManager
  ext.parcelMods = overhaul_career_logistics_parcelMods
  ext.vehicleTasks = overhaul_career_logistics_vehicleTasks
  ext.materialContracts = overhaul_career_logistics_materialContractManager
  ext.step = overhaul_shell_stepHandler
end

M.onExtensionLoaded = function()
  overhaul_shell_patches.registerFields(parts.navigation.MAP_PATCH_ID, function() return rawget(_G, "freeroam_bigMapMode") end, {
    toggleBigMap = parts.navigation.toggleBigMapWrapper,
  })
end
M.onExtensionUnloaded = function()
  if overhaul_shell_patches then overhaul_shell_patches.unregister(parts.navigation.MAP_PATCH_ID) end
end

M.setBigMapPanEnabled = parts.navigation.setBigMapPanEnabled
M.enterCargoOverviewScreen = parts.navigation.enterCargoOverviewScreen
M.exitCargoOverviewScreen = parts.navigation.exitCargoOverviewScreen
M.onCargoOverviewRouteLeave = parts.navigation.onCargoOverviewRouteLeave
M.commitDeliveryConfiguration = parts.commit.commitDeliveryConfiguration
M.cancelDeliveryConfiguration = parts.commit.cancelDeliveryConfiguration
M.setBestRoute = parts.navigation.setBestRoute
M.onCargoPickedUp = parts.navigation.onCargoPickedUp
M.onOverhaulDeliveryRewardsPopupClosed = parts.navigation.onOverhaulDeliveryRewardsPopupClosed
M.onDeactivateBigMapCallback = parts.navigation.onDeactivateBigMapCallback

M.deliveryMarkerSelected = parts.navigation.deliveryMarkerSelected

M.onBigmapHoveredPoiIdChanged = function(poiId)
  if not screen.cargoOverviewScreenOpen then return end
  parts.navigation.highlightCargoInPoi(poiId or freeroam_bigMapMode.selectedPoiId)
end

M.showRoutePreview = parts.navigation.showRoutePreview
M.showLocationRoutePreview = parts.navigation.showLocationRoutePreview
M.showCargoRoutePreview = parts.navigation.showCargoRoutePreview
M.showVehicleOfferRoutePreview = parts.navigation.showVehicleOfferRoutePreview
M.highlightCargoInPoi = parts.navigation.highlightCargoInPoi
M.setCargoRoute = parts.navigation.setCargoRoute
M.setVisibleIdsForBigMap = parts.navigation.setVisibleIdsForBigMap

M.exitDeliveryMode = function()
  if ext.general.isDeliveryModeActive() then
    extensions.hook("onGameplayActivityAborted")
  end
  ext.general.exitDeliveryMode(true)
end
M.showCargoContainerHelpPopup = function()
  overhaul_career_guide_tutorialPopups.introPopup("cargoContainerHowTo", true)
end
M.unloadCargoPopupClosed = function() ext.progress.unloadCargoPopupClosed() end
M.requestDropOffData = function(...) ext.progress.requestDropOffData(...) end
M.confirmDropOffData = function(...) ext.progress.confirmDropOffData(...) end
M.clearTransientMoveForCargo = function(...) ext.parcelManager.clearTransientMoveForCargo(...) end

M.dropOffPopupClosed = function(mode)
  ext.progress.dropOffPopupClosed(mode)
  if mode == "results" then
    extensions.hook("onOverhaulDeliveryRewardsPopupClosed")
  end
  if mode == "cargoSelection" then
    extensions.hook("onOverhaulDeliveryDropOffCargoSelectionPopupClosed")
  end
end

M.activity = require('overhaul/career/logistics/cargoScreen/activity')(M)

return M
