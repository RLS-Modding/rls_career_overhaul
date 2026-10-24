// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Owned-property listings for the real estate phone view: the owned garage list,
// asking prices and guidance per garage, and the offers sub-view. The view passes in
// the Lua bridge and the confirmation prompt; it keeps the tab state that decides
// when a refresh happens, so this composable never reads the view's tabs itself.
import { ref, reactive } from 'vue'

export function usePhoneRealEstateListings({ lua, openConfirmation }) {
  const ownedListings = ref([])
  const listingPrices = reactive({})
  const listingGuidance = reactive({})
  const selectedOwnedGarage = ref(null)
  const selectedOwnedOffers = ref([])
  const listingsSubView = ref('owned')

  const defaultListingPrice = (garage) => {
    return Number(garage?.askingPrice) > 0 ? Number(garage.askingPrice) : Math.max(0, Number(garage?.marketValue) || 0)
  }

  const syncListingInputs = () => {
    for (const garage of ownedListings.value) {
      if (!garage) continue
      const id = garage.garageId
      if (listingPrices[id] == null) {
        listingPrices[id] = defaultListingPrice(garage)
      }
    }
  }

  const setListingsSubView = (view) => {
    if (view === 'owned') {
      selectedOwnedOffers.value = []
      selectedOwnedGarage.value = null
    }
    listingsSubView.value = view
  }

  const refreshOwnedListings = async () => {
    if (!lua.overhaul_career_garage_garageManager?.getOwnedGaragesListingData) return
    const data = await lua.overhaul_career_garage_garageManager.getOwnedGaragesListingData()
    ownedListings.value = Array.isArray(data) ? data : []
    syncListingInputs()
  }

  const openOwnedOffers = async (garage) => {
    if (!garage?.garageId) return
    const data = await lua.overhaul_career_garage_garageManager.getGarageOffersData(garage.garageId)
    if (!data) {
      selectedOwnedGarage.value = { ...garage, garageId: garage.garageId }
      selectedOwnedOffers.value = []
    } else {
      selectedOwnedGarage.value = data
      selectedOwnedOffers.value = data.offers || []
    }
    listingsSubView.value = 'offers'
  }

  const getGuidance = async (garage) => {
    const askingPrice = Number(listingPrices[garage.garageId])
    const value = Number.isFinite(askingPrice) && askingPrice > 0 ? askingPrice : defaultListingPrice(garage)
    const data = await lua.overhaul_career_garage_garageManager.getGarageListingPriceGuidanceByGarageId(garage.garageId, value)
    listingGuidance[garage.garageId] = data || null
  }

  const listGarageForSale = async (garage) => {
    if (!garage?.garageId) return
    const askingPrice = Number(listingPrices[garage.garageId])
    const value = Number.isFinite(askingPrice) && askingPrice > 0 ? askingPrice : defaultListingPrice(garage)
    await lua.overhaul_career_garage_garageManager.listGarageForSaleByGarageId(garage.garageId, value)
    await refreshOwnedListings()
  }

  const confirmMoveOut = async (garage) => {
    if (!garage?.canMoveOut || !garage?.garageId) return
    const ok = await openConfirmation(
      'Move Out',
      `Move out of ${garage.name || 'this garage'}?\n\nYou will lose access with no refund. You can reclaim it for free later from Real Estate.`
    )
    if (!ok) return
    await lua.overhaul_career_garage_garageManager.moveOutOfGarage(garage.garageId)
    await refreshOwnedListings()
  }

  const confirmReclaim = async (garage) => {
    const garageId = garage?.id || garage?.garageId
    if (!garageId || !garage?.canReclaim) return
    const ok = await openConfirmation(
      'Reclaim Garage',
      `Reclaim ${garage.name || 'this garage'} for free?`
    )
    if (!ok) return
    await lua.overhaul_career_garage_garageManager.reclaimGrantedGarage(garageId)
    await refreshOwnedListings()
    lua.overhaul_phone_apps_realEstate.requestGarageListings()
  }

  const confirmReclaimOwned = async (garage) => {
    await confirmReclaim(garage)
  }

  const removeOwnedListing = async (garage) => {
    if (!garage?.computerId) return
    await lua.overhaul_career_garage_garageManager.removeGarageListing(garage.computerId)
    if (selectedOwnedGarage.value && selectedOwnedGarage.value.garageId === garage.garageId && listingsSubView.value === 'offers') {
      listingsSubView.value = 'owned'
      selectedOwnedGarage.value = null
      selectedOwnedOffers.value = []
    }
    await refreshOwnedListings()
  }

  const acceptOwnedOffer = async (offer) => {
    const garageId = selectedOwnedGarage.value?.garageId
    if (!garageId || !offer?.index) return
    await lua.overhaul_career_garage_garageManager.acceptOffer(garageId, offer.index)
    await refreshOwnedListings()
    if (listingsSubView.value === 'offers') {
      listingsSubView.value = 'owned'
      selectedOwnedGarage.value = null
      selectedOwnedOffers.value = []
    }
  }

  const declineOwnedOffer = async (offer) => {
    const garageId = selectedOwnedGarage.value?.garageId
    if (!garageId || !offer?.index) return
    await lua.overhaul_career_garage_garageManager.declineOffer(garageId, offer.index)
    await openOwnedOffers(selectedOwnedGarage.value)
  }

  const negotiateOwnedOffer = async (offer) => {
    const garageId = selectedOwnedGarage.value?.garageId
    if (!garageId || !offer?.index) return
    await lua.overhaul_career_garage_property_realEstateNegotiation.startNegotiateSelling(garageId, offer.index, 'phone')
  }

  return {
    ownedListings, listingPrices, listingGuidance, selectedOwnedGarage, selectedOwnedOffers, listingsSubView,
    defaultListingPrice, syncListingInputs, setListingsSubView, refreshOwnedListings, openOwnedOffers, getGuidance,
    listGarageForSale, confirmMoveOut, confirmReclaim, confirmReclaimOwned, removeOwnedListing,
    acceptOwnedOffer, declineOwnedOffer, negotiateOwnedOffer,
  }
}
