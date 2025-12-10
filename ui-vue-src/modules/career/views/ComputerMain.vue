<template>
  <ComputerWrapper :title="computerStore.computerData.facilityName + ' - Home screen'" close @back="close">

    <BngCard class="card-content" v-bng-blur="1" >
      <BngCardHeading v-if="computerLoading">
        Loading...
      </BngCardHeading>

      <div v-if="!computerLoading" class="computer-actions">
        <div class="action-header">
          <div class="line left"></div>
          <div class="title">Vehicle Management</div>
          <div class="line right"></div>
        </div>
        <div v-if="hasVehicles" class="vehicle-select-container">
          <div class="vehicle-select" >
            <BngButton style="height: 3em;" v-if="showVehicleSelectorButtons" :accent="ACCENTS.ghost" @click="switchActiveVehicle(-1)" v-bng-on-ui-nav:tab_l.asMouse :icon="icons.arrowLargeLeft">
              <BngBinding ui-event="tab_l" deviceMask="xinput" />
            </BngButton>
              <VehicleTileRow
                class="vehicle-tile-row"
                :class="{ 'hasButtons': showVehicleSelectorButtons }"
                :data="currentVehicleData"
                :enableHover="false"
                :small="true"
              />

            <BngButton style="height: 3em;" v-if="showVehicleSelectorButtons" :accent="ACCENTS.ghost" @click="switchActiveVehicle(1)" v-bng-on-ui-nav:tab_r.asMouse :icon="icons.arrowLargeRight">
              <BngBinding ui-event="tab_r" deviceMask="xinput" />
            </BngButton>
          </div>

          <div class="actions-list" v-if="computerStore.activeInventoryId && computerStore.vehicleSpecificComputerFunctions[computerStore.activeInventoryId]">
            <div class="computer-function-tile"
              v-for="(computerFunction, index) in computerStore.vehicleSpecificComputerFunctions[computerStore.activeInventoryId]"
              :key="computerFunction.id"
              :class="{ 'action-disabled': computerFunction.disabled }"
              tabindex="0" bng-nav-item v-bng-on-ui-nav:ok.asMouse.focusRequired
              @click="computerButtonCallback(computerFunction, computerStore.activeInventoryId)"
              @mouseover="setReason(0, infoById[computerFunction.id].reason)"
              @focus="setReason(0, infoById[computerFunction.id].reason)"
              @mouseleave="setReason(0)"
              @blur="setReason(0)"
              v-bng-ui-nav-focus="index == 0 ? 0 : undefined"
            >
              <BngIcon class="icon" :type="infoById[computerFunction.id].icon" />
              <span class="label">{{ infoById[computerFunction.id].label }}</span>
            </div>
          </div>
        </div>

        <div v-else class="no-vehicle-container">
          <span>No vehicles in garage.</span>
          <p> Place a vehicle in your garage to access modify and manage it.</p>
        </div>

        <div class="action-header" v-if="computerStore.generalComputerFunctions">
          <div class="line left"></div>
          <div class="title">General Computer Functions</div>
          <div class="line right"></div>
        </div>
        <div v-if="computerStore.generalComputerFunctions" class="general-functions-container">
          <div class="actions-list">
            <template v-for="(computerFunction, index) in computerStore.generalComputerFunctions" :key="computerFunction.id">
              <div class="computer-function-tile"
                v-if="!computerFunction.type"
                :class="{ 'action-disabled': computerFunction.disabled }"
                tabindex="0"
                bng-nav-item v-bng-on-ui-nav:ok.asMouse.focusRequired
                @click="computerButtonCallback(computerFunction)"
                @mouseover="setReason(1, infoById[computerFunction.id].reason)"
                @focus="setReason(1, infoById[computerFunction.id].reason)"
                @mouseleave="setReason(1)"
                @blur="setReason(1)"
                v-bng-ui-nav-focus="!hasVehicles && index == 0 ? 0 : undefined"
                >
                <BngIcon class="icon" :type="infoById[computerFunction.id].icon" />
                <span class="label">{{ infoById[computerFunction.id].label }}</span>
              </div>
            </template>
          </div>
          <div class="disable-reason" v-if="disableReason[0]">
            <BngIcon class="disable-icon" v-show="disableReason[0]" :type="icons.info" />
            <span v-html="disableReason[0] || '&nbsp;'"></span>
          </div>
          <div class="disable-reason" v-if="disableReason[1]">
            <BngIcon class="disable-icon"  :type="icons.info" />
            <span v-html="disableReason[1] || '&nbsp;'"></span>
          </div>
        </div>

        <div class="action-header">
          <div class="line left"></div>
          <div class="title">Activities & Events</div>
          <div class="line right"></div>
        </div>
        <div class="activities-container">
          <div class="actions-list">
            <template v-for="(computerFunction, index) in computerStore.activityComputerFunctions" :key="computerFunction.id">
              <div class="computer-function-tile"
                v-if="!computerFunction.type"
                :class="{ 'action-disabled': computerFunction.disabled }"
                tabindex="0"
                bng-nav-item v-bng-on-ui-nav:ok.asMouse.focusRequired
                @click="computerButtonCallback(computerFunction)"
                @mouseover="setReason(2, infoById[computerFunction.id].reason)"
                @focus="setReason(2, infoById[computerFunction.id].reason)"
                @mouseleave="setReason(2)"
                @blur="setReason(2)"
                >
                <BngIcon class="icon" :type="infoById[computerFunction.id].icon" />
                <span class="label">{{ infoById[computerFunction.id].label }}</span>
              </div>
            </template>
          </div>
          <div class="disable-reason" v-if="disableReason[2]">
            <BngIcon class="disable-icon" :type="icons.info" />
            <span v-html="disableReason[2] || '&nbsp;'"></span>
          </div>
        </div>
      </div>
    </BngCard>
  </ComputerWrapper>
</template>

<script setup>
import { ref, computed, onMounted, onUnmounted, watch } from "vue"
import { lua } from "@/bridge"
import { useComputerStore } from "../stores/computerStore"
import ComputerWrapper from "./ComputerWrapper.vue"
import { BngButton, ACCENTS, BngCard, BngCardHeading, BngBinding, BngIcon, icons } from "@/common/components/base"
// import { default as UINavEvents, UI_EVENT_GROUPS } from "@/bridge/libs/UINavEvents"
import { getUINavServiceInstance, UI_EVENT_GROUPS } from "@/services/uiNav"
import { vBngOnUiNav, vBngBlur, vBngUiNavFocus } from "@/common/directives"
import VehicleTileRow from "../components/vehicleInventory/VehicleTileRow.vue"

const computerStore = useComputerStore()
const currentVehicleData = ref(null)

watch(() => computerStore.activeInventoryId, (newId) => {
  if (Number(newId)) {
    lua.career_modules_inventory.getVehicleUiData(newId).then(data => {
      currentVehicleData.value = data
    })
  }
})

const showVehicleSelectorButtons = computed(() => computerStore.computerData.vehicles && computerStore.computerData.vehicles.length > 1 )

const hasVehicles = computed(() => computerStore.computerData.vehicles && computerStore.computerData.vehicles.length)

// list of function IDs that are known to take some time, so we inform the user about loading
const slowFunctions = ["vehicleShop", "partInventory"]
const computerLoading = ref(false)

const computerButtonCallback = (computerFunction, inventoryId = undefined) => {
  if (computerFunction.disabled) return
  if (slowFunctions.includes(computerFunction.id)) {
    computerLoading.value = true
    // for some reason, both nextTick and window.requestAnimationFrame does not produce the desired result
    setTimeout(() => computerStore.computerButtonCallback(computerFunction.id, inventoryId), 100)
  } else {
    computerStore.computerButtonCallback(computerFunction.id, inventoryId)
  }
}
const switchActiveVehicle = computerStore.switchActiveVehicle

const iconById = {
  painting: icons.sprayCan,
  partShop: icons.doorFrontCoins,
  repair: icons.wrench,
  tuning: icons.cogs,
  insurances: icons.shieldHandCheckmark,
  playerAbstract: icons.personSolid,
  vehicleInventory: icons.keys1,
  partInventory: icons.engine,
  vehicleShop: icons.carCoins,
  performanceIndex: icons.raceFlag,
  carMeets: icons.cars,
  sleep: icons.night,
  loans: icons.beamCurrency,
}

const infoById = computed(() => [
  ...computerStore.generalComputerFunctions,
  ...(computerStore.activeInventoryId ? computerStore.vehicleSpecificComputerFunctions[computerStore.activeInventoryId] : undefined) || [],
  ...computerStore.activityComputerFunctions,
].reduce((res, func) => {
  res[func.id] = {
    icon: iconById[func.id] || icons.bug,
    label: func.label,
    reason: undefined,
  }
  if (func.reason) {
    /// nbsp by size:
    // narrow: " "
    // normal: " "
    // figure: " "
    res[func.id].label += " *"
    // string "func.disableReason" is for backward compatibility with an old style
    res[func.id].reason = func.reason.label
    // TODO: alternate something when "func.disableReason.type" is not "text" (discussion is on-going)
  }
  return res
}, {}))

const isTutorialActive = ref(false)
const disableReason = ref([null, null, null])
const setReason = (idx, reason = null) => {
  disableReason.value = disableReason.value.map((_, i) => i === idx ? reason : null)
}

const close = () => {
  if (computerLoading.value) return
  lua.career_career.closeAllMenus()
}

const start = async () => {
  // UINavEvents.setFilteredEvents(UI_EVENT_GROUPS.focusMoveScalar)
  getUINavServiceInstance().setFilteredEvents(UI_EVENT_GROUPS.focusMoveScalar)
  computerStore.requestComputerData()

  if (Number(computerStore.activeInventoryId)) {
    lua.career_modules_inventory.getVehicleUiData(computerStore.activeInventoryId).then(data => {
      currentVehicleData.value = data
    })
  }
  lua.career_modules_linearTutorial.isLinearTutorialActive().then(data => {
    isTutorialActive.value = data
  })
}

const kill = () => {
  computerStore.onMenuClosed()
  // UINavEvents.clearFilteredEvents()
  getUINavServiceInstance().clearFilteredEvents()
  computerStore.$dispose()
}

onMounted(start)
onUnmounted(kill)
</script>

<style scoped lang="scss">
@use "@/styles/modules/mixins" as *;

.card-content {
  width: max-content;
  max-width: 100%;
  min-width: 50rem;
  height: 100%;
  color: white;
  background-color: var(--bng-black-8);
  & :deep(.card-cnt) {
    background-color: rgba(0, 0, 0, 0);
    gap: 2rem;
  }
}

.computer-actions {
  display: flex;
  flex-direction: column;
  overflow: auto;
  padding: 1rem;
  gap: 1rem;
}

.vehicle-select-container {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  padding-bottom: 1rem;
}

.general-functions-container {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  padding-bottom: 1rem;
}

.activities-container {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  padding-bottom: 1rem;
}

.action-header {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  .title {
    font-size: 1.25rem;
    font-weight: 500;
  }
  .line {
    flex: 1;
    height: 1px;
    background-color: var(--bng-cool-gray-600);
    &.left {
      flex: 0 0 1rem;
    }
    &.right {
    }
  }
}

.vehicle-select {
  display: inline-flex;
  justify-content: space-between;
  align-items: stretch;
  font-size: 1rem;
  width: 100%;

  background-color: var(--bng-black-6);
  border-radius: var(--bng-corners-1);
  border: 1px solid rgba(255, 255, 255, 0.15);

  .vehicle-tile-row {
    flex: 1;
    background:none;
    border:none;
    border-radius: 0;
    &.hasButtons{
      border-left: 1px solid rgba(255, 255, 255, 0.1);
      border-right: 1px solid rgba(255, 255, 255, 0.1);
    }
  }

  > button {
    min-width: 3em !important;
    height: unset !important;
    justify-content: center;
    display: flex;
    align-items: center;
    flex-flow: column;
    // width: 3em;
  }
}



.actions-list {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(20rem, 1fr));
  gap: 0.5rem;
}

.computer-function-tile {
  // Setting round corners and focus frame offset for focusable tile
  $f-offset: 0.25rem;
  $rad: var(--bng-corners-1);

  position: relative;
  display: flex;
  align-items: center;
  gap: 0.5em;
  padding: 0.5em;
  width: 100%;
  border-radius: $rad;
  background-color: rgba(0, 0, 0, 0.6);
  transition: background-color ease-in 75ms;
  border: 1px solid rgba(255, 255, 255, 0.15);

  .icon {
    font-size: 2.5em;
  }
  .label {
    flex: 1 1 auto;
    font-size: 1.3em;
    font-weight: 400;
    text-align: left;
  }

  // Modify the focus frame radius and offset based on tile corner radius
  @include modify-focus($rad, $f-offset);

  &:focus,
  &:hover {
    background-color: rgba(var(--bng-cool-gray-700-rgb), 0.8);
  }
}

.action-disabled {
  filter: brightness(70%);
  cursor: default !important;
}

.disable-reason {
  display: flex;
  align-items: center;
  justify-content: center;
  background-color: rgba(var(--bng-cool-gray-700-rgb), 0.8);
  border-radius: var(--bng-corners-1);
  padding: 0.5em;
  .disable-icon {
    margin-right: 0.1em;
    margin-bottom: 0.2em;
  }
}

.class-info-wrapper {
  display: inline-block;
  margin-left: 0.5em;
  vertical-align: middle;
}

.class-info {
  display: inline-flex;
  align-items: center;
  gap: 0.25em;
  font-size: 0.9em;

  .separator {
    color: #888;
    margin: 0 0.25em;
  }

  .class-details {
    display: flex;
    gap: 0.35em;
    align-items: center;
    padding-bottom: 3px;
  }

  .class-name {
    color: #ccc;
  }

  .performance-index {
    display: inline-flex;
    font-weight: 600;
    border-radius: var(--bng-corners-1);
    overflow: hidden;
    align-items: center;

    .class-segment {
      background: #666;
      color: #fff;
      padding: 0.15em 0.4em;
      display: flex;
      align-items: center;
    }

    .number-segment {
      background: #444;
      color: #fff;
      padding: 0.15em 0.4em;
      display: flex;
      align-items: center;
    }
  }

  .class-na {
    color: #888;
  }

  .class-badge {
    display: inline-flex;
    align-items: center;
    background-color: rgba(90, 78, 20, 0.541);
    padding: 6px 8px 2px 8px;
    border-radius: 999px;
    color: #f0a500;
  }
}

</style>
