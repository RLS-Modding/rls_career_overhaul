<template>
  <div style="color:white">#Hello</div>
  <ComputerWrapper
    v-if="cargoOverviewStore.cargoData"
    :path="['My Cargo']"
    :title="'My Cargo 2'"
    back @back="close">

    <template #status>
      Delivery Lvl 2 |
      Car Jockey Lvl 3 |
      Facility Reputation: Good
      <!--
      <div class="item">
        Penalty for abandoning deliveries:
        <BngUnit :money="cargoOverviewStore.cargoData.player.penaltyForAbandon" />
      </div>
      <div class="item">
        Reward sum:
        <BngUnit :money="cargoOverviewStore.cargoData.player.loadedCargoMoneySum" />
      </div>
      <div class="item">
        Cargo weight:
        {{ units.buildString("weight", cargoOverviewStore.cargoData.player.weightSum, 1) }}
      </div>
        -->
    </template>

    <template #top>
      <div style="width: 100%; padding: 0.3em; background:#8888ff;">
        FILTERTABS
      </div>
    </template>

    <!-- panel-grid or panel-flex -->
    <div class="panel-flex">

      <BngCard class="content-row provided-orders-panel">
        <BngCardHeading type="ribbon" class="cardHeading">
          My Cargo
        </BngCardHeading>
        <BngSwitch v-model="cargoOverviewStore.automaticRoute"> Automatic route </BngSwitch>
        <BngSlider :min="0" :max="cargoOverviewStore.cargoData.playerCardGroupSets.length-1" :step="1" v-model="cargoOverviewStore.playerGroupingIdx" @change="cargoOverviewStore.setGroupingAndSorting" />
        <BngSlider :min="0" :max="cargoOverviewStore.cargoData.sortingSets.length-1" :step="1" v-model="cargoOverviewStore.playerSortingIdx" @change="cargoOverviewStore.setGroupingAndSorting" />
        <BngCardHeading type="ribbon" class="cardHeading">
          Grouped {{cargoOverviewStore.cargoData.playerCardGroupSets[cargoOverviewStore.playerGroupingIdx].label}}, Sorted {{cargoOverviewStore.cargoData.sortingSets[cargoOverviewStore.playerSortingIdx].label}}
        </BngCardHeading>
        <div style="overflow-y: scroll;">
          <ProvidedOrdersPanel
            :groupSets = "cargoOverviewStore.cargoData.playerCardGroupSets"
            :groupIdx = "cargoOverviewStore.playerGroupingIdx"
            :sortingSets = "cargoOverviewStore.cargoData.sortingSets"
            :sortIdx = "cargoOverviewStore.playerSortingIdx"
            @cardHovered="cargoOverviewStore.cardHovered" @cardClicked="cargoOverviewStore.cardClicked"
          />

        </div>

      </BngCard>

      <div class="content-row selected-and-map-panel">
        <BngCard class="cargo-detail">
          <BngCardHeading type="ribbon" class="cardHeading">
            Details View
          </BngCardHeading>
          <div class="content" v-if="cargoOverviewStore.focusedCargo" >
            <CargoCard  :card="cargoOverviewStore.focusedCargo" detailed />
            <!---<div style="color:white">{{cargoOverviewStore.focusedCargo.transientMoveCounts}}
              {{cargoOverviewStore.focusedCargo.autoLoadLocations}}
            </div>-->
          </div>
          <template #buttons v-if="cargoOverviewStore.focusedCargo">
              <!-- Parcel Group Buttons-->
            <template v-if="cargoOverviewStore.focusedCargo.cardType == 'parcelGroup'">
              <template v-if="cargoOverviewStore.focusedCargo.isFacilityCard">
                <BngButton
                  :disabled="!cargoOverviewStore.focusedCargo.enabled || cargoOverviewStore.focusedCargo.transientMoveCounts == 0"
                  accent="text"
                  @click="cargoOverviewStore.clearLoad(cargoOverviewStore.focusedCargo)">
                  Clear Load
                </BngButton>
                <BngButton
                  :disabled="!cargoOverviewStore.focusedCargo.enabled || cargoOverviewStore.focusedCargo.autoLoadLocations && cargoOverviewStore.focusedCargo.autoLoadLocations.length == 0"
                  accent="text"
                  @click="cargoOverviewStore.loadCargoCustom(cargoOverviewStore.focusedCargo)">
                  Custom Load
                </BngButton>
                <BngButton
                  :disabled="!cargoOverviewStore.focusedCargo.enabled || cargoOverviewStore.focusedCargo.autoLoadLocations && cargoOverviewStore.focusedCargo.autoLoadLocations.length <= cargoOverviewStore.focusedCargo.transientMoveCounts"
                  @click="cargoOverviewStore.loadCargoAuto(cargoOverviewStore.focusedCargo)">
                  Auto Load
                </BngButton>
              </template>
              <template v-if="cargoOverviewStore.focusedCargo.isPlayerCard">
                <BngButton
                  accent="text"
                  :disabled="cargoOverviewStore.focusedCargo.transientCargo"
                  @click="cargoOverviewStore.changeDistribution(cargoOverviewStore.focusedCargo)">
                  Change Distribution
                </BngButton>
                <BngButton
                  :disabled="cargoOverviewStore.focusedCargo.transientCargo"
                  @click="cargoOverviewStore.clearLoad(cargoOverviewStore.focusedCargo)">
                  Clear Load
                </BngButton>
              </template>
            </template>
            <template v-if="cargoOverviewStore.focusedCargo.cardType == 'storage'">
              <template v-if="cargoOverviewStore.focusedCargo.isFacilityCard">
                <BngButton
                  :disabled="!cargoOverviewStore.focusedCargo.enabled"
                  @click="cargoOverviewStore.loadStorageCustom(cargoOverviewStore.focusedCargo)">
                  Load Custom
                </BngButton>
              </template>

            </template>

            <template v-if="cargoOverviewStore.focusedCargo.cardType == 'vehicleOffer'">
                <BngButton
                  :disabled="!cargoOverviewStore.focusedCargo.enabled"
                  @click="cargoOverviewStore.loadOffer(cargoOverviewStore.focusedCargo)">
                  {{cargoOverviewStore.focusedCargo.spawnWhenCommitingCargo ? 'Don\'t bring out' : 'Bring Out'}}
                </BngButton>

            </template>





          </template>
        </BngCard>
        <BngCard class="map">
          Map Screen
        </BngCard>
      </div>


    </div>

  </ComputerWrapper>
</template>
<script>
const TAB_HEADINGS = {
  parcels: "Parcels",
  smallFluids: "Fluid Orders",
  largeFluids: "Fluid Custom",
  smallDryBulk: "Dry Bulk Orders",
  largeDryBulk: "Dry Bulk Custom",
  smallCement: "Cement Orders",
  largeCement: "Cement Custom",
  smallCash: "Cash Orders",
  largeCash: "Cash Custom",
  vehicles: "Vehicles",
  trailers: "Trailers",
  loaners: "Loaners",
}
</script>

<script setup>
import { lua, useBridge } from "@/bridge"
import { useCargoOverviewStore } from "../stores/cargoOverviewStore"
import { onMounted, onUnmounted, ref } from "vue"
import { BngButton, BngCard, BngScreenHeading, BngBinding, BngProgressBar, BngCardHeading, BngSlider, BngSwitch} from "@/common/components/base"
import { Tabs, TabList, Tab } from "@/common/components/utility"
import { vBngOnUiNav, vBngBlur } from "@/common/directives"
import { useUINavScope } from "@/services/uiNav"
import { LayoutSingle } from "@/common/layouts"


import ProvidedOrdersPanel from "../components/cargoOverview/panels/ProvidedOrdersPanel.vue"

import CargoCard from "../components/cargoOverview/CargoCard.vue"
import CardGroup from "../components/cargoOverview/CardGroup.vue"
import { openScreenOverlay, addPopup } from "@/services/popup"
import CargoLoadPopup from "../components/cargoOverview/CargoLoadPopup.vue"

import ComputerWrapper from "./ComputerWrapper.vue"

const playerGroupingIdx = ref(3)
const playerSortingIdx = ref(1)


const { events } = useBridge()

useUINavScope("myCargo")

const props = defineProps({
  facilityId: String,
  parkingSpotPath: String,
})

const playerCargoRef = ref(null)
const sectionTabs = ref()
const activeTabHeading = ref(TAB_HEADINGS.parcels)

const progress = ref()

const acceptedVehiclesTarget = ref()

const cargoOverviewStore = useCargoOverviewStore()

const updateCargoDataAll = () => {
  cargoOverviewStore.requestCargoData(props.facilityId, props.parkingSpotPath)
}

const goToLoanerScreen = () => {
  if (!cargoOverviewStore.cargoData) return
  let loanerScreenIndex = 0
  if (cargoOverviewStore.cargoData.availableSystems.parcelDelivery) loanerScreenIndex++
  if (cargoOverviewStore.cargoData.availableSystems.fluidDelivery) loanerScreenIndex++
  if (cargoOverviewStore.cargoData.availableSystems.vehicleDelivery) loanerScreenIndex++
  if (cargoOverviewStore.cargoData.availableSystems.trailerDelivery) loanerScreenIndex++
  sectionTabs.value.selectTab(loanerScreenIndex)
}

const close = () => {
  //lua.career_modules_delivery_cargoScreen.commitDeliveryConfiguration()
  lua.career_modules_delivery_cargoScreen.exitCargoOverviewScreen()
}

const exitMode = () => {
  lua.career_modules_delivery_cargoScreen.exitDeliveryMode()
  lua.career_modules_delivery_cargoScreen.exitCargoOverviewScreen()
}

const start = () => {
  lua.career_modules_delivery_cargoScreen.setCargoScreenTab("all")
  updateCargoDataAll()
}

const hoveredFacilityCargo = cargo => {
  if (cargo) {
    if (cargo.remainingOfferTime > 0) {
      playerCargoRef.value.highlightEmptySlots(cargo.slots)
      lua.career_modules_delivery_cargoScreen.showCargoRoutePreview(cargo.id)
    }
  } else {
    playerCargoRef.value.highlightEmptySlots(0)
    lua.career_modules_delivery_cargoScreen.showCargoRoutePreview(undefined)
  }
}

const hoveredPlayerCargo = cargo => {
  if (cargo) {
    lua.career_modules_delivery_cargoScreen.showCargoRoutePreview(cargo.id)
  } else {
    lua.career_modules_delivery_cargoScreen.showCargoRoutePreview(undefined)
  }
}

events.on("updateCargoData", updateCargoDataAll)

const kill = () => {
  cargoOverviewStore.menuClosed()
  events.off("updateCargoData", updateCargoDataAll)
  // cargoOverviewStore.$dispose()
}
onMounted(start)
onUnmounted(kill)
</script>

<style scoped lang="scss">

:deep(.bng-card-wrapper > .card-cnt) {
  flex: 1 1 auto;
}

.facilityCargo {
  flex: 1 1 auto;
  margin-bottom: 1em;
  min-height: 35vh;
}

.facilityCargoSlim {
  flex: 1 1 auto;
  margin-bottom: 1em;
  min-height: 15vh;
}

.playerCargo {
  flex: 1 1 60%;
}

.cargoScreen {
  max-width: 80em;

}

.cargoLists {
  display: flex;
  align-self: flex-start;
  flex-flow: column;
  flex: 1 1 auto;
  max-width: 80em;
  max-height: 70vh;
  // max-height: 60vh;
  & > *:not(:last-child) {
    margin-bottom: 0.75rem;
  }

  .cargoCard {
    color: white;
    background-color: rgba(63, 63, 63, 0.8);
  }
  .actions {
    flex: 0 0 auto;
  }
}

.cargoTabs > :deep(.tab-content) {
  height: 100%;
  overflow: hidden;
}

.reputationCard {
  color: white;
  margin-bottom: 1em;
}

// progress
// .page-stats-wrapper > * {
//   width: 95%;
// }

.progressbar-fill {
  align-self: stretch;
  border-radius: var(--bng-corners-1);
  box-sizing: content-box;
  height: 0.8em;
}

.progressbar-background {
  align-self: stretch;
  border-radius: var(--bng-corners-1);
  height: 1.5em;
}

.main-stat-progress-bar {
  font-size: 1.5rem;
  padding: 0.5em 1em;
}

.reputation-bar {
  font-size: 0.8rem;
  height: 2.5em;
}


.panel-grid {
  display: grid;
  gap: 1rem;
  grid-template-columns: repeat(2, 1fr); /* Change column widths here */
  grid-template-rows: 100%;
  padding: 1rem;
  flex: 1 1 auto;

  background-color:#181818ff;
  height:100%;
  position:relative;
  overflow:hidden;

  .content-row {
    justify-self:row;
    align-self:stretch;
    height:auto;

  }

  .provided-orders-panel {
    grid-column: 1;
    //TODO: fix background colors
    background-color:white;

  }
  .selected-and-map-panel {

    grid-column: 2;

    display: grid;
    gap: 1rem;
    grid-template-rows: repeat 2 1fr; /* First row hugs the content, second row grows */


    .cargo-detail {
      //background-color:var(--bng-ter-blue-gray-800);

      grid-row: 1;
      height:auto;
      }
    .map{

      grid-row: 2;
      height:auto;
    }

  }
  .cardHeading {
    color:white;
  }
}

.panel-flex {
  flex: 1 1 auto;
  display: flex;
  justify-content: space-between;
  align-content: flex-start;
  padding: 1rem;

  background-color:#181818ff;
  height:100%;
  position:relative;
  overflow:hidden;

  > * {
    flex: 0 0 calc(50.000% - 0.5rem);
  }

  .content-row {
    align-self: stretch;
    height:auto;
  }

  .provided-orders-panel {
    //TODO: fix background colors
    background-color:var(--bng-ter-blue-gray-800);
  }

  .selected-and-map-panel {
    display: flex;
    flex-direction: column;
    align-content: stretch;
    overflow: hidden;
    .cargo-detail {
      flex: 0 0 auto;
      margin-bottom: 1rem;
      //background-color:var(--bng-ter-blue-gray-800);
    }
    .map {
      flex: 1 1 auto;
    }

  }
  .my-cargo-panel {
    //background-color:var(--bng-ter-blue-gray-800);

    grid-column: 3;
  }
  .cardHeading {
    color:white;
  }
}
</style>
