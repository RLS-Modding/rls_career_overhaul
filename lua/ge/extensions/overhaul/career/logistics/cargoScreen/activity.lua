-- Per-load definition; calls the current facade exports without dispatching hooks.
-- The callbacks retain this owner table so a reloaded instance cannot reuse the old owner's state.

return function(M)
  local function call(name) return function(...) return M[name](...) end end
  return {
    id = 'cargoDelivery', label = 'Cargo delivery', role = 'orchestrator', modes = {'career'},
    extension = 'overhaul_career_logistics_cargoScreen', lifecycle = 'cargoDelivery',
    actions = {
      abandonAcceptedOffer = call('abandonAcceptedOffer'),
      abandonMaterialContract = call('abandonMaterialContract'),
      acceptMaterialContract = call('acceptMaterialContract'),
      applyTransientMoves = call('applyTransientMoves'),
      clearTransientMoveForCargo = call('clearTransientMoveForCargo'),
      closeEngineShopSupplyPickupScreen = call('closeEngineShopSupplyPickupScreen'),
      closeMaterialContractPickupScreen = call('closeMaterialContractPickupScreen'),
      closePassiveBusinessSupplyPickupScreen = call('closePassiveBusinessSupplyPickupScreen'),
      confirmDropOffData = call('confirmDropOffData'),
      dropOffPopupClosed = call('dropOffPopupClosed'),
      enterCargoOverviewScreen = call('enterCargoOverviewScreen'),
      enterEngineShopSupplyPickupScreen = call('enterEngineShopSupplyPickupScreen'),
      enterMaterialContractPickupScreen = call('enterMaterialContractPickupScreen'),
      enterMyCargo = call('enterMyCargo'),
      enterPassiveBusinessSupplyPickupScreen = call('enterPassiveBusinessSupplyPickupScreen'),
      loadEngineShopSupply = call('loadEngineShopSupply'),
      loadMaterialContract = call('loadMaterialContract'),
      loadPassiveBusinessSupply = call('loadPassiveBusinessSupply'),
      moveCargoFromUi = call('moveCargoFromUi'),
      onPassiveBusinessSupplyPickupRouteLeave = call('onPassiveBusinessSupplyPickupRouteLeave'),
      requestCargoDataForUi = call('requestCargoDataForUi'),
      requestDropOffData = call('requestDropOffData'),
      requestEngineShopSupplyPickupData = call('requestEngineShopSupplyPickupData'),
      requestMaterialContractPickupData = call('requestMaterialContractPickupData'),
      requestPassiveBusinessSupplyPickupData = call('requestPassiveBusinessSupplyPickupData'),
      setCargoScreenTab = call('setCargoScreenTab'),
      setMaterialContractPickupRoute = call('setMaterialContractPickupRoute'),
      showCargoRoutePreview = call('showCargoRoutePreview'),
      showRoutePreview = call('showRoutePreview'),
      toggleOfferForSpawning = call('toggleOfferForSpawning'),
    },
    transitions = {}, resources = {'vehicle', 'tasklist'}, settlement = 'owner', economyKeys = {},
  }
end
