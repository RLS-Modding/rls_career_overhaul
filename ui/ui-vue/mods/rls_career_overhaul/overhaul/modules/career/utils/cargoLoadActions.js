// This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
// If a copy of the bCDDL was not distributed with this
// file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
// RLS modifications: Copyright (C) RLS Modding

import { defineAsyncComponent } from "vue"
import { lua } from "@/bridge"
import { openConfirmation, addPopup, confirmCancelButtons } from "@/services/popup"
import { $translate } from "@/services/translation"

// Popup components import the data store, so load them only when the user opens a popup.
const CargoLoadPopup = defineAsyncComponent(() => import("../components/cargoOverview/CargoLoadPopup.vue"))
const CargoScreenSettings = defineAsyncComponent(() => import("../components/cargoOverview/CargoScreenSettings.vue"))

// Actions from the cargo screen cards: loading, clearing and abandoning, plus the menu lifecycle
export function createCargoLoadActions({
  cargoData, dropDownData, selectedFilter, facilityFilter, selectedCargo, activeScrollScopes, requestCargoDataSimple,
}) {
  let loadingPrompt = null

  const menuClosed = () => {
    cargoData.value = undefined
    dropDownData.value = {}
    selectedFilter.value = facilityFilter
    selectedCargo.value = undefined
    activeScrollScopes.value.clear()
    lua.overhaul_career_logistics_cargoScreen.showCargoRoutePreview(undefined)
    loadingPrompt && loadingPrompt.close(null)
  }

  const setScrollScopeActive = (scopeId, active) => {
    if (active) activeScrollScopes.value.add(scopeId)
    else activeScrollScopes.value.delete(scopeId)
  }

  const openCargoScreenSettings = () => {
    addPopup(CargoScreenSettings)
  }

  const clearLoad = cargo => {
    for (let id of cargo.ids) {
      lua.overhaul_career_logistics_cargoScreen.clearTransientMoveForCargo(id)
    }
    requestCargoDataSimple()
  }

  const throwAway = card => {
    loadingPrompt = addPopup(CargoLoadPopup,{cargo: card}).promise
  }

  const loadCargoAuto = cargo => {
    // clear all transient moves for this group
    for (let id of cargo.ids) {
      lua.overhaul_career_logistics_cargoScreen.clearTransientMoveForCargo(id)
    }
    //if(cargo.transientMoveCounts <= 0) {
      let idx = 0
      for(let loc of cargo.autoLoadLocations) {
        lua.overhaul_career_logistics_cargoScreen.moveCargoFromUi(cargo.ids[idx], loc)
        idx++;
      }
    //}
    requestCargoDataSimple()

  }

  const loadOffer = (offer) => {
    lua.overhaul_career_logistics_cargoScreen.toggleOfferForSpawning(offer.id)
    requestCargoDataSimple()
  }

  const loadLoaner = (offer) => {
    lua.overhaul_career_logistics_loanerVehicles.markForSpawning(offer)
    requestCargoDataSimple()
  }

  const returnLoaner = vehId => {
    lua.overhaul_career_logistics_loanerVehicles.returnVehicle(vehId).then(() => {
      requestCargoDataSimple()
    })
  }

  async function abandonOffer(card) {
    const message = $translate.instant("ui.career.cargoOverview.confirm.abandonOffer", {
      name: card.name,
      penalty: card.abandonInfo.penaltyMoney,
    })
    const res = await openConfirmation(null, message, confirmCancelButtons({ destructive: true }), "", false)
    if (res) {
      lua.overhaul_career_logistics_cargoScreen.abandonAcceptedOffer(card.abandonInfo.vehId)
      requestCargoDataSimple()
    }
  }

  return {
    setScrollScopeActive, menuClosed, openCargoScreenSettings, clearLoad, throwAway,
    loadCargoAuto, loadOffer, loadLoaner, returnLoaner, abandonOffer,
  }
}

