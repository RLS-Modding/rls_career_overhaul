// This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
// If a copy of the bCDDL was not distributed with this
// file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
// RLS modifications: Copyright (C) RLS Modding

// Cargo store map: selection and filters; payload intake and move requests; reactive setup and lifecycle.
// Popup sessions and component loading belong to the cargoLoadActions interaction owner.
import { onScopeDispose, computed, ref, watch } from "vue"
import { defineStore } from "pinia"
import { lua, useBridge } from "@/bridge"
import { openConfirmation, confirmCancelButtons } from "@/services/popup"
import { $translate } from "@/services/translation"
import { createCargoLoadActions } from "../utils/cargoLoadActions.js"
// custom 'forEach' to check if it's an array first - some empty data from Lua seems to come back as an empty object rather than []
const _forEach = (arr, func) => Array.isArray(arr) && arr.length > 0 && arr.forEach(func)

// The store setup creates its refs and computeds first, in the order the store has always used, then builds the
// groups below. A group only creates closures over the refs it is given, so no Vue call happens inside a group.

// Which card is selected, hovered or focused, and the route the hovered card previews
function createCardSelection({ focusedCargo, selectedCargo }) {
  const onCargoHovered = (cargo) => {
    // if(!cargo && selectedCargo.value)
    //   focusedCargo.value = selectedCargo.value
    // else
      focusedCargo.value = cargo
    highlightRoute(focusedCargo.value)
  }

  const onCargoSelected = (cargo) => {
    selectedCargo.value = cargo
  }

  const highlightRoute = (card) => {
    if(card ) {
      lua.overhaul_career_logistics_cargoScreen.showRoutePreview(card.route)
    } else {
      lua.overhaul_career_logistics_cargoScreen.showRoutePreview(undefined)
    }
  }

  const cardDeselect = () => onCargoSelected()

  const cardHovered = card => {
    onCargoHovered(card)
  }

  return { onCargoHovered, onCargoSelected, cardHovered, cardDeselect }
}

// The facility and player tabs, and the grouping and sorting cycles for each
function createFacilityFilters({
  cargoData, selectedCargo, facilityGroupingKey, facilitySortingKey, playerGroupingKey, playerSortingKey, filterSets,
  selectedFilter, facilityGroupings, facilitySortings, playerSortings,
}) {
  const playerGroupings = ['containers', 'tasklist','ungrouped']

  const selectFilter = (f) => {
    lua.overhaul_career_logistics_general.setSetting("selectedFilterKey", f)
    lua.overhaul_career_logistics_cargoScreen.setCargoScreenTab(f)
    for(let filter of filterSets.value) {
      if(filter.value == f[0]) {
        let prevGrouping = facilityGroupingKey.value
        let prevSorting = facilitySortingKey.value


        selectedFilter.value = filter
        if(!filter.isFacilityPage) {
          if(!filter.groupings.includes(prevGrouping)) {
            facilityGroupingKey.value = filter.groupings[0]
          }
          if(!cargoData.value.facilityCardGroupSets[facilityGroupingKey.value].sortings.includes(prevSorting)) {
            facilitySortingKey.value = cargoData.value.facilityCardGroupSets[facilityGroupingKey.value].sortings[0]
          }
          if(selectedCargo.value && selectedCargo.value.isFacilityCard) {
            let contained = selectedCargo.value.filterTags[filter.value]
            if(contained) {
              for(let groupKey of filter.groupings) {
                for(let group of cargoData.value.facilityCardGroupSets[groupKey].groups){
                    contained = contained || group.cardIdsUnsorted.includes(selectedCargo.value.cardId)
                }
              }
            }
            if(!contained) {
              selectedCargo.value = undefined
            }
          }
        }
      }
    }
  }

  const nextFacilityGrouping = () => {
    let groups = facilityGroupings.value
    facilityGroupingKey.value = groups[(groups.indexOf(facilityGroupingKey.value) + 1) % groups.length]
  }
  const nextFacilitySorting = () => {
    let group = facilitySortings.value
    facilitySortingKey.value = group[(group.indexOf(facilitySortingKey.value) + 1) % group.length]
  }

  const nextPlayerGrouping = () => {
    let groups = playerGroupings
    playerGroupingKey.value = groups[(groups.indexOf(playerGroupingKey.value) + 1) % groups.length]
  }
  const nextPlayerSorting = () => {
    let group = playerSortings.value
    playerSortingKey.value = group[(group.indexOf(playerSortingKey.value) + 1) % group.length]
  }

  const setGroupingAndSorting = () => {
    // Compatibility API: grouping and sorting stay local; this does not persist settings.
  }

  return {
    selectFilter, nextFacilityGrouping, nextFacilitySorting, nextPlayerGrouping, nextPlayerSorting, setGroupingAndSorting,
    playerGroupings,
  }
}

// Whether the best route is drawn automatically and whether drop-off is detailed, and the Lua calls behind each
function createRouteSettings({ automaticRoute, detailedDropOff }) {
  const setAutomaticRoute = (newValue, oldValue) => {
    if (newValue == oldValue) return
    lua.overhaul_career_logistics_general.setAutomaticRoute(newValue)
  }

  const getAutomaticRoute = enabled => {
    automaticRoute.value = enabled
  }

  const setDetailedDropOff = (newValue, oldValue) => {
    if (newValue == oldValue) return
    lua.overhaul_career_logistics_general.setDetailedDropOff(newValue)
  }

  const getDetailedDropOff = enabled => {
    detailedDropOff.value = enabled
  }

  return { setAutomaticRoute, getAutomaticRoute, setDetailedDropOff, getDetailedDropOff }
}

// Which cards the Lua side has highlighted, and which facility storage locations are highlighted
function createHighlightState({ cargoData, cargoHighlighted, highlightedCards }) {
  const highlightFacilityIds = highlightedIdMap => {
    cargoHighlighted.value = Object.keys(highlightedIdMap).length > 0

    if (cargoData.value && cargoData.value.facility) {
      _forEach(cargoData.value.facility.materialStorageData, storage => {
        storage.highlight = false
        _forEach(storage.locations, loc => {
          loc.highlight = highlightedIdMap && highlightedIdMap[loc.id]
          storage.highlight = storage.highlight || loc.highlight
        })
      })
    }
  }

  const highlightCardIds = highlightedIdMap => {
    highlightedCards.value = highlightedIdMap
  }

  return { highlightCardIds }
}

// Applies a cargo payload from Lua to the store, and re-selects the previously selected card when it is still there
function createCargoDataState({
  cargoData, dropDownData, tutorialInfo, selectedCargo, onCargoSelected, automaticRoute, getAutomaticRoute,
  getDetailedDropOff, setAutomaticRoute, filterSets, filterSetsByValue, facilityFilter, selectedFilter,
}) {
  const setCargoData = data => {
    let previousCardId
    if(selectedCargo.value) {
      previousCardId = selectedCargo.value.cardId
    }
    if (data) cargoData.value = data

    dropDownData.value = {}
    if (!cargoData.value.player) return
    if (!cargoData.value.player.vehicles) return

    getAutomaticRoute(data.settings.automaticRoute)
    getDetailedDropOff(data.settings.detailedDropOff)

    // we call this here to redraw the best route
    if (automaticRoute.value) {
      setAutomaticRoute(automaticRoute.value)
    }

    filterSets.value = data.filterSets
    filterSets.value.unshift(facilityFilter)

    for(let filter of filterSets.value) {
      filterSetsByValue.value[filter.value] = filter
    }

    if(!selectedFilter.value)
      selectedFilter.value = filterSets.value[0]

    //re-select previous card if we can
    if(previousCardId) {
      onCargoSelected(cargoData.value.cardsById[previousCardId])
    }

    tutorialInfo.value = data.tutorialInfo
  }

  return { setCargoData }
}

// Requests for cargo data from Lua, and moving cargo between locations (with a confirmation when it costs a penalty)
function createCargoRequests({ newCargoAvailable, setCargoData }) {
  let facilityId
  let parkingSpotPath

  const requestCargoData = (_facilityId, _parkingSpotPath, updateMaxTimeStamp) => {
    facilityId = _facilityId
    parkingSpotPath = _parkingSpotPath
    lua.overhaul_career_logistics_cargoScreen.requestCargoDataForUi(facilityId, parkingSpotPath, updateMaxTimeStamp)
    if (updateMaxTimeStamp != false) newCargoAvailable.value = false

  }
  const requestCargoDataSimple = () => {
    requestCargoData(facilityId, parkingSpotPath, false)
  }

  const moveCargoToLocation = (cargoId, targetLocation, skipRequest) => {
    lua.overhaul_career_logistics_cargoScreen.moveCargoFromUi(cargoId, targetLocation)
    if(!skipRequest) requestCargoData(facilityId, parkingSpotPath, false)
  }

  const requestMoveCargoToLocation = (cargoId, moveData, skipRequest) => {
    //console.log(cargoId, moveData, skipRequest)
    if (moveData.extraData) {
      openThrowAwayPopup(
        cargoId,
        moveData.location,
        $translate.instant("ui.career.cargoOverview.confirm.throwAwayWithPenalty", {
          penalty: moveData.extraData.penalty.toFixed(2),
        })
      )
    } else {
      moveCargoToLocation(cargoId, moveData.location, skipRequest)
    }
  }

  async function openThrowAwayPopup(cargoId, targetLocation, message) {
    const res = await openConfirmation(null, message, confirmCancelButtons({ destructive: true }), "", false)
    if (res) {
      moveCargoToLocation(cargoId, targetLocation)
    } else {
      // the value of the dropdown needs to be reset here and we do it in the lazy way by resetting all the cargo data
      setCargoData()
    }
  }

  return { requestCargoData, requestCargoDataSimple, requestMoveCargoToLocation }
}

export const useCargoOverviewStore = defineStore("overhaulCargoOverview", () => {
  const { events } = useBridge()

  // Refs and computeds, created in the store's original order. Vue's ref, computed and $translate calls happen here
  // and nowhere else in the setup, before the groups below are built.
  const cargoData = ref()
  const dropDownData = ref({})
  const newCargoAvailable = ref(false)
  const cargoHighlighted = ref(false)
  const automaticRoute = ref(false)
  const detailedDropOff = ref(false)
  const tutorialInfo = ref()
  const activeScrollScopes = ref(new Set())
  const facilityGroupingKey = ref("destinations")
  const facilitySortingKey = ref("rewardMoney")
  const facilitySortAsc = ref(false)

  const playerGroupingKey = ref("tasklist")
  const playerSortingKey = ref("cardId")
  const playerSortAsc = ref(true)

  let facilityFilter = {value:"facility-info",label: $translate.instant("ui.career.cargoOverview.facilityInfo"), showInFilterTabs:true, isFacilityPage:true}
  let filterSets = ref({})
  let filterSetsByValue = ref({})
  let selectedFilterRef = ref()
  let selectedFilter = ref(facilityFilter)

  const facilityGroupings = computed(() => selectedFilter.value ? selectedFilter.value.groupings : [])
  const facilitySortings = computed(() => cargoData.value && facilityGroupingKey.value && cargoData.value.facilityCardGroupSets && cargoData.value.facilityCardGroupSets[facilityGroupingKey.value] ? cargoData.value.facilityCardGroupSets[facilityGroupingKey.value].sortings : [])
  const playerSortings = computed(() => cargoData.value && playerGroupingKey.value && cargoData.value.playerCardGroupSets && cargoData.value.playerCardGroupSets[playerGroupingKey.value] ? cargoData.value.playerCardGroupSets[playerGroupingKey.value].sortings : [])
  const currentFilterTutorialInfo = computed(() => {
    if (!tutorialInfo.value || !selectedFilter.value) return null
    const info = tutorialInfo.value[selectedFilter.value.value]
    if (!info || !info.unlocked || !info.isActive) return null
    return info
  })
  const loanerOffers = computed(() => {
    if (!cargoData.value || !cargoData.value.facility || !cargoData.value.facility.loanableVehicles) return []
    let result = []
    result = result.concat(cargoData.value.facility.loanableVehicles)
    return result
  })

  const highlightedCards = ref({})
  const focusedCargo = ref()
  const hoveredCargo = ref()
  const selectedCargo = ref()

  // Groups: closures over the state above
  const selection = createCardSelection({ focusedCargo, selectedCargo })
  const filters = createFacilityFilters({
    cargoData, selectedCargo, facilityGroupingKey, facilitySortingKey, playerGroupingKey, playerSortingKey, filterSets,
    selectedFilter, facilityGroupings, facilitySortings, playerSortings,
  })
  const route = createRouteSettings({ automaticRoute, detailedDropOff })
  const highlights = createHighlightState({ cargoData, cargoHighlighted, highlightedCards })
  const cargo = createCargoDataState({
    cargoData, dropDownData, tutorialInfo, selectedCargo, onCargoSelected: selection.onCargoSelected, automaticRoute,
    getAutomaticRoute: route.getAutomaticRoute, getDetailedDropOff: route.getDetailedDropOff,
    setAutomaticRoute: route.setAutomaticRoute, filterSets, filterSetsByValue, facilityFilter, selectedFilter,
  })
  const requests = createCargoRequests({ newCargoAvailable, setCargoData: cargo.setCargoData })
  const loads = createCargoLoadActions({
    cargoData, dropDownData, selectedFilter, facilityFilter, selectedCargo, activeScrollScopes,
    requestCargoDataSimple: requests.requestCargoDataSimple,
  })

  watch(() => automaticRoute.value, route.setAutomaticRoute)
  watch(() => detailedDropOff.value, route.setDetailedDropOff)

  function handleNewCargoAvailable() {
    newCargoAvailable.value = true
  }

  function dispose() {
    events.off("automaticRouteSet", route.getAutomaticRoute)
    events.off("cargoDataForUiReady", cargo.setCargoData)
    events.off("newCargoAvailable", handleNewCargoAvailable)
    events.off("sendHighlightedCardIds", highlights.highlightCardIds)
    events.off("requestCargoDataSimple", requests.requestCargoDataSimple)
  }
  onScopeDispose(dispose)

  events.on("automaticRouteSet", route.getAutomaticRoute)
  events.on("cargoDataForUiReady", cargo.setCargoData)
  events.on("newCargoAvailable", handleNewCargoAvailable)
  events.on("sendHighlightedCardIds", highlights.highlightCardIds)
  events.on("requestCargoDataSimple", requests.requestCargoDataSimple)

  return {
    cargoData,
    tutorialInfo,
    onCargoHovered: selection.onCargoHovered,
    onCargoSelected: selection.onCargoSelected,
    loanerOffers,
    dropDownData,
    newCargoAvailable,
    cargoHighlighted,
    automaticRoute,
    detailedDropOff,
    setGroupingAndSorting: filters.setGroupingAndSorting,
    requestCargoData: requests.requestCargoData,
    requestCargoDataSimple: requests.requestCargoDataSimple,
    requestMoveCargoToLocation: requests.requestMoveCargoToLocation,
    menuClosed: loads.menuClosed,
    activeScrollScopes,
    setScrollScopeActive: loads.setScrollScopeActive,
    dispose,
    focusedCargo,
    selectedCargo,

    cardHovered: selection.cardHovered,
    cardDeselect: selection.cardDeselect,
    clearLoad: loads.clearLoad,
    loadCargoAuto: loads.loadCargoAuto,
    throwAway: loads.throwAway,
    loadOffer: loads.loadOffer,
    abandonOffer: loads.abandonOffer,
    loadLoaner: loads.loadLoaner,
    returnLoaner: loads.returnLoaner,

    filterSets,
    filterSetsByValue,
    selectedFilterRef,
    selectedFilter,
    selectFilter: filters.selectFilter,
    highlightedCards,
    openCargoScreenSettings: loads.openCargoScreenSettings,

    nextFacilityGrouping: filters.nextFacilityGrouping,
    nextFacilitySorting: filters.nextFacilitySorting,
    nextPlayerGrouping: filters.nextPlayerGrouping,
    nextPlayerSorting: filters.nextPlayerSorting,
    facilityGroupingKey,
    facilitySortingKey,
    facilitySortAsc,
    playerGroupingKey,
    playerSortingKey,
    playerSortAsc,
    facilityGroupings,
    facilitySortings,
    playerGroupings: filters.playerGroupings,
    playerSortings,
    currentFilterTutorialInfo,

  }
})
