<!--*** Refuelling Interface  -->
<template>
  <LayoutSingle v-if="refuelStore.currentFuelData">
    <BngCard class="refuel-card">
      <BngCardHeading type="ribbon">{{ $t(refuelStore.gasStationName) }}</BngCardHeading>
      <div class="gauge">
        <FuelGauge
          class="main-gauge"
          :fuelling="refuelStore.isFuelling"
          :type="mainSettings.gaugeType"
          :value="refuelStore.currentFuelLevel"
          :label="refuelStore.isFuelling ? $t(mainSettings.fuellingOngoingLabel) : ''"
          :minLabel="refuelStore.minEnergyLabel"
          :maxLabel="refuelStore.maxEnergyLabel" />
      </div>
      <FuelNozzle
        :refuel-type="refuelStore.currentFuelType"
        :nozzle-mode="refuelStore.nozzleMode"
        @triggerDown="refuelStore.changeFlowRate(1)"
        @triggerUp="refuelStore.changeFlowRate(0)" />
      <FuelInfo
      :total-cost="refuelStore.overallPrice"
      :price-per-unit="refuelStore.currentFuelData.pricePerUnit"
      :unit-label="mainSettings.unitLabel"
      :fuel-discount-data="refuelStore.fuelDiscountData"
      />
      <div class="settings content" v-if="refuelStore.showFuelTypeSettings || refuelStore.showAmountSettings">
        <FuelTypeSettings v-if="refuelStore.showFuelTypeSettings" :fuel-options="refuelStore.fuelOptions" />
        <FuelAmountSettings
          v-if="refuelStore.showAmountSettings"
          :min-slider="refuelStore.minSlider"
          :max-slider="refuelStore.maxSlider"
          :unit-label="mainSettings.unitLabel" />
        </div>
      <template #buttons>
        <BngButton v-if="refuelStore.canPay" @click="refuelStore.payPrice()">Pay</BngButton>
        <BngButton v-if="refuelStore.canStartFuelling" @click="refuelStore.startFuelling()">{{ $t(mainSettings.startLabel) }}</BngButton>
        <BngButton v-else-if="refuelStore.canStopFuelling" @click="refuelStore.stopFuelling()">Stop</BngButton>
      </template>
    </BngCard>
  </LayoutSingle>
  <div class="status-container">
    <CareerStatus class="profileStatus" />
    <TaskList class="tasklist"
      :header="store.header"
      :tasks="store.tasks" />
  </div>
</template>

<script>
import { icons } from "@/assets/icons"

const fuellingModes = {
  fuel: {
    title: "ui.career.refuelling.modes.fuel.title",
    gaugeType: "refuel",
    nozzleIconType: icons.general.fuel_nozzle,
    fuellingOngoingLabel: "ui.career.refuelling.modes.fuel.ongoing",
    startLabel: "ui.career.refuelling.modes.fuel.start",
    unitLabel: "L",
  },
  charge: {
    title: "ui.career.refuelling.modes.charge.title",
    gaugeType: "recharge",
    nozzleIconType: icons.general.recharge_connector,
    fuellingOngoingLabel: "ui.career.refuelling.modes.charge.ongoing",
    startLabel: "ui.career.refuelling.modes.charge.start",
    unitLabel: "kWh",
  },
}
</script>

<script setup>
import { onBeforeUnmount, onUnmounted, computed, onBeforeMount, provide } from "vue"
import { useRefuelStore } from "@/modules/refuel/refuelStore"
import { LayoutSingle } from "@/common/layouts"
import { BngCard, BngCardHeading, BngButton } from "@/common/components/base"
import FuelGauge from "@/modules/refuel/components/FuelGauge.vue"
import FuelTypeSettings from "../components/FuelTypeSettings.vue"
import FuelNozzle from "../components/FuelNozzle.vue"
import FuelInfo from "../components/FuelInfo.vue"
import FuelAmountSettings from "../components/FuelAmountSettings.vue"
import { CareerStatus } from "@/modules/career/components"
import { TaskList } from '@/modules/tasks'
import { useTasksStore } from '@/modules/tasks'
import { useLibStore } from '@/services'

const { $game } = useLibStore()

const refuelStore = useRefuelStore()
const mainSettings = computed(() => fuellingModes[refuelStore.currentFuelType])

onBeforeMount(() => {
  refuelStore.requestFuelingData()
})

onBeforeUnmount(() => {
  refuelStore.cancelTransaction()
})

onUnmounted(() => {
  refuelStore.$dispose()
})

const store = useTasksStore()

provide('animationSettings', {
  animate: true,
  animateOnMount: false,
  animateOnMountIntervalDelay: 0.2,
  animateOnEmptyIntervalDelay: 0.1,
  animateOnEmpty: true,
  animateNextTask: true,
  successCallback: playAudio
})

function playAudio() {
  $game.lua.Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Checkbox')
}
</script>

<style lang="scss" scoped>
$textcolor: #fff;
$fontsize: 16px;

.layout-content {
  color: $textcolor;
  font-size: $fontsize;
  padding: 1em;
}

.gauge {
  display: flex;
  justify-content: center;
  margin-top: -36px;
  padding: 0.5em 1em 0;
}

.refuel-card {
  align-self: center;
  width: 330px;
  color: $textcolor;

  :deep(.footer-container) {
    background-color: transparent;
    border-top: none;
  }
}

.main-gauge {
  width: 246px;
  height: 246px;
}

:deep(.nozzle) {
  position: absolute;
  left: 100%;
  top: 0;
  mask-position: 0 45%;
  -webkit-mask-position: 0 45%;
  margin-left: 0.2em;
}

.status-container {
  position: absolute;
  top: 0.5rem;
  right: 0.5rem;
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}

.tasklist {
  max-width: 35rem;
}

.profileStatus {
  align-self: flex-end;
  border-radius: var(--bng-corners-2);
  color: white;
  background-color: rgba(0, 0, 0, 0.7);
  & :deep(.card-cnt) {
    background-color: rgba(0, 0, 0, 0.7);
  }
}
</style>
