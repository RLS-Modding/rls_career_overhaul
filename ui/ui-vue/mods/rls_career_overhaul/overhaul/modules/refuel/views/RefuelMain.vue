<!--*** Refuelling Interface  -->
<template>
  <!-- House refuel screen: same nav, labels and store calls as before; the card, tank picker, buttons,
       breadcrumb and status chips use the career house style. Gauge + nozzle stay the game's own. -->
  <LayoutSingle
    v-if="refuelStore.currentFuelData"
    v-bng-scoped-nav="{ scopeId: 'career-refueling', type: 'nonav', activateOnMount: true }"
    v-bng-on-ui-nav:ok="onPayNav"
    v-bng-on-ui-nav:back,menu="onExitNav"
    v-bng-on-ui-nav:context="onPumpFuelNav"
    v-bng-on-ui-nav:tab_l="onTankPreviousNav"
    v-bng-on-ui-nav:tab_r="onTankNextNav"
    v-bng-ui-nav-label:ok="$t('ui.career.refueling.pay')"
    v-bng-ui-nav-label:context="$t(pumpFuelLabel)"
    v-bng-ui-nav-label:back,menu="$t('ui.common.back')"
    tabindex="-1">
    <div class="refuel-panel">
      <BngBreadcrumbs
        class="refuel-breadcrumbs"
        :items="breadcrumbItems"
        :hide-last-item="false"
        disable-last-item
        show-back-button
        :navigable="false"
        @back="onExitNav" />

      <section class="rls-house refuel-card" v-bng-blur="1">
        <header class="refuel-head">
          <span class="kicker">{{ $t(mainSettings.title) }}</span>
          <h2 class="station">{{ $t(refuelStore.gasStationName) }}</h2>
        </header>

        <div class="gauge">
          <FuelGauge
            class="main-gauge"
            :fuelling="refuelStore.isFuelling"
            :type="mainSettings.gaugeType"
            :value="refuelStore.currentFuelLevel"
            :energy-type="refuelStore.currentEnergyType"
            :label="refuelStore.isFuelling ? $t(mainSettings.fuellingOngoingLabel) : ''"
            :minLabel="refuelStore.minEnergyLabel"
            :maxLabel="refuelStore.maxEnergyLabel" />
        </div>
        <FuelNozzle
          :refuel-type="refuelStore.currentFuelType"
          :energy-type="refuelStore.currentEnergyType"
          :nozzle-mode="refuelStore.nozzleMode"
          :fill-level="refuelStore.flowRate"
          @triggerDown="refuelStore.changeFlowRate(1)"
          @triggerUp="refuelStore.changeFlowRate(0)" />
        <FuelInfo
          :total-cost="refuelStore.overallPrice"
          :price-per-unit="refuelStore.currentFuelData.pricePerUnit"
          :unit-label="mainSettings.unitLabel"
          :fuel-discount-data="refuelStore.fuelDiscountData" />
        <div class="settings content" v-if="refuelStore.showFuelTypeSettings || refuelStore.showAmountSettings">
          <FuelTypeSettings v-if="refuelStore.showFuelTypeSettings" :fuel-options="refuelStore.fuelOptions" />
          <FuelAmountSettings
            v-if="refuelStore.showAmountSettings"
            :min-slider="refuelStore.minSlider"
            :max-slider="refuelStore.maxSlider"
            :unit-label="mainSettings.unitLabel" />
        </div>

        <div class="refuel-actions">
          <!-- tanks: one segment each (LB / RB switch on a controller, same as the old arrow select) -->
          <div v-if="refuelStore.hasMultipleTanks" class="tank-bar">
            <BngBinding class="tank-binding" controller ui-event="tab_l" track-ignore />
            <div class="seg bar tank-seg">
              <button
                v-for="opt in refuelStore.tankOptions"
                :key="opt.value"
                type="button"
                bng-no-nav="true"
                tabindex="-1"
                :class="{ active: opt.value === refuelStore.selectedTankIndex }"
                :disabled="refuelStore.isFuelling"
                @click="onTankSelectChange(opt.value)">
                <span class="tank-name">{{ $ctx_t(opt.label) }}</span>
                <span class="tank-type">{{ energyName(opt.tank) }}</span>
              </button>
            </div>
            <BngBinding class="tank-binding" controller ui-event="tab_r" track-ignore />
          </div>

          <HouseButton
            block
            class="refuel-btn refuel-pump"
            :class="{ pumping: refuelStore.isAutoFuelling }"
            :style="refuelActionStyle"
            bng-no-nav="true"
            :nav-item="false"
            :tabindex="-1"
            :disabled="!refuelStore.canRefuel && !refuelStore.isAutoFuelling"
            @click="onPumpFuelNav">
            <BngBinding class="btn-binding" controller ui-event="context" track-ignore />
            {{ $t(pumpFuelLabel) }}
          </HouseButton>
          <HouseButton
            block
            variant="primary"
            class="refuel-btn"
            bng-no-nav="true"
            :nav-item="false"
            :tabindex="-1"
            :disabled="!refuelStore.canPay"
            @click="onPayNav">
            <BngBinding class="btn-binding" controller ui-event="ok" track-ignore />
            {{ $t("ui.career.refueling.pay") }}
          </HouseButton>
        </div>
      </section>
    </div>
  </LayoutSingle>
  <div class="status-container">
    <CareerStatus class="profileStatus" />
    <TaskList class="tasklist"
      :header="store.header"
      :tasks="store.tasks" />
  </div>
</template>

<script>
const fuellingModes = {
  fuel: {
    title: "ui.career.refuelling.modes.fuel.title",
    gaugeType: "refuel",
    fuellingOngoingLabel: "ui.career.refuelling.modes.fuel.ongoing",
    startLabel: "ui.career.refuelling.modes.fuel.start",
    stopLabel: "ui.career.refuelling.modes.fuel.stop",
    manualLabel: "ui.career.refuelling.modes.fuel.pumpManual",
    unitLabel: "L",
  },
  charge: {
    title: "ui.career.refuelling.modes.charge.title",
    gaugeType: "recharge",
    fuellingOngoingLabel: "ui.career.refuelling.modes.charge.ongoing",
    startLabel: "ui.career.refuelling.modes.charge.start",
    stopLabel: "ui.career.refuelling.modes.charge.stop",
    manualLabel: "ui.career.refuelling.modes.charge.chargeManual",
    unitLabel: "kWh",
  },
}
</script>

<script setup>
import { onBeforeUnmount, onUnmounted, computed, onBeforeMount, provide, watch } from "vue"
import { useRefuelStore } from "../refuelStore"
import { LayoutSingle } from "@/common/layouts"
import { BngBinding, BngBreadcrumbs } from "@/common/components/base"
import { HouseButton } from "../../career/components/house/index.js"
import { $translate } from "@/services/translation"
import { vBngOnUiNav, vBngScopedNav, vBngUiNavLabel, vBngBlur } from "@/common/directives"
import FuelGauge from "@/modules/refuel/components/FuelGauge.vue"
import FuelTypeSettings from "@/modules/refuel/components/FuelTypeSettings.vue"
import FuelNozzle from "@/modules/refuel/components/FuelNozzle.vue"
import FuelInfo from "../components/FuelInfo.vue"
import FuelAmountSettings from "@/modules/refuel/components/FuelAmountSettings.vue"
import CareerStatus from "../../career/components/careerStatus.vue"
import { TaskList } from '@/modules/tasks'
import { useTasksStore } from "@/services/tasklistStore"
import { useInfoBar } from "@/services/infoBar"
import { useUINavBlocker } from "@/services/uiNavTracker"
import { useBridge } from '@/bridge'
import { getFuelTypeColors } from "@/modules/refuel/fuelTypes"

const { lua } = useBridge()

const refuelStore = useRefuelStore()
const infoBar = useInfoBar()
const uiNavBlocker = useUINavBlocker()

const mainSettings = computed(() => fuellingModes[refuelStore.currentFuelType] || fuellingModes.fuel)
const pumpFuelLabel = computed(() => refuelStore.isAutoFuelling ? mainSettings.value.stopLabel : mainSettings.value.startLabel)
const refuelActionStyle = computed(() => {
  const colors = getFuelTypeColors(refuelStore.currentEnergyType, refuelStore.currentFuelType)
  return {
    "--refuel-action-color": colors.button.enabled,
    "--refuel-action-active-color": colors.button.active,
    "--refuel-action-border-color": colors.button.border,
  }
})
// tank segment: the game's localized caption (ui.career.refueling.tankIndex, "Tank 2 / 2") over the fuel type
const energyName = tank => {
  const type = tank?.energyType
  if (!type) return ""
  const key = `ui.general.fuelType.${type}`
  const text = $translate.instant(key)
  return text && text !== key ? text : type
}
const breadcrumbItems = Object.freeze([
  { label: "ui.career.refueling.title" },
])
const MANUAL_PUMP_HINT_ID = "refuel-manual-pump"
const manualPumpHint = computed(() => ({
  id: MANUAL_PUMP_HINT_ID,
  content: {
    type: "binding",
    props: {
      action: "fuelVehicle",
      controller: true,
    },
    label: mainSettings.value.manualLabel,
  },
}))

onBeforeMount(() => {
  refuelStore.requestFuelingData()
  uiNavBlocker.allowOnly(["ok", "back", "menu", "context", "tab_l", "tab_r", "rotate_h_cam", "rotate_v_cam"])
})

onBeforeUnmount(() => {
  refuelStore.cancelTransaction()
})

onUnmounted(() => {
  infoBar.removeHints(MANUAL_PUMP_HINT_ID)
  uiNavBlocker.clear()
  refuelStore.$dispose()
})

watch(manualPumpHint, hint => {
  infoBar.removeHints(MANUAL_PUMP_HINT_ID)
  infoBar.addHints(hint)
}, { immediate: true })

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
  lua.Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Checkbox')
}

async function onPayNav() {
  if (!refuelStore.canPay) return false
  await refuelStore.payPrice()
  return false
}

async function onPumpFuelNav() {
  if (refuelStore.isAutoFuelling) {
    await refuelStore.stopFuelling()
    return false
  }
  await refuelStore.startFuelling()
  return false
}

function onTankSelectChange(index) {
  refuelStore.setSelectedTankIndex(index)
  return false
}

function onTankPreviousNav() {
  refuelStore.selectPreviousTank()
  return false
}

function onTankNextNav() {
  refuelStore.selectNextTank()
  return false
}

async function onExitNav() {
  await refuelStore.cancelTransaction()
  return false
}
</script>

<style lang="scss" scoped>
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.refuel-panel {
  align-self: center;
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 0.5rem;
}

/* house card: near-black panel, station name as the title (no ribbon) */
.refuel-card.rls-house {
  position: relative; // the nozzle hangs off its right edge
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  width: 21em;
  padding: 0.95em 1em 1em;
  border-radius: var(--radius-control);
  background: rgba(var(--bng-off-black-rgb), 0.92);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
  color: #fff;
}
.refuel-head {
  display: grid;
  gap: 0.15em;
  .kicker {
    color: var(--accent);
    font-size: 0.72em;
    font-weight: 800;
    letter-spacing: 0.1em;
    text-transform: uppercase;
  }
  .station {
    margin: 0;
    font-size: 1.25em;
    font-weight: 800;
    line-height: 1.2;
  }
}

.gauge {
  display: flex;
  justify-content: center;
  margin-top: 0.2em;
}
.main-gauge {
  width: 15.4em;
  height: 15.4em;
}
:deep(.nozzle) {
  position: absolute;
  left: 100%;
  top: 0;
  mask-position: 0 45%;
  -webkit-mask-position: 0 45%;
  margin-left: 0.4em;
}

.refuel-actions {
  display: grid;
  gap: 0.45em;
  margin-top: 0.2em;
}

/* tanks: house joined bar, LB / RB hints at the ends */
.tank-bar {
  display: flex;
  align-items: center;
  gap: 0.4em;
}
.tank-seg {
  flex: 1 1 auto;
  min-width: 0;
  button {
    flex: 1 1 0;
    display: grid;
    gap: 0.1em;
    justify-items: center;
    padding-top: 0.5em;
    padding-bottom: 0.4em;
    line-height: 1.1;
  }
  .tank-name {
    font-weight: 800;
  }
  .tank-type {
    color: var(--faint);
    font-size: 0.8em;
    font-weight: 600;
  }
  button.active .tank-type {
    color: var(--muted);
  }
}
.tank-binding {
  flex: 0 0 auto;
  font-size: 0.95em;
}

.refuel-btn {
  gap: 0.5em;
  min-height: 2.6em;
  .btn-binding {
    display: inline-flex;
    align-items: center;
    font-size: 1em;
  }
}
// pumping: the start/stop button pulses in the fuel type's own colour
.refuel-pump.pumping {
  color: #fff;
  background: color-mix(in srgb, var(--refuel-action-color, #ff6600) 28%, transparent);
  box-shadow: inset 0 0 0 1px var(--refuel-action-border-color, #ff6600);
  animation: refuel-pump-pulse 1s ease-in-out infinite alternate;
}
@keyframes refuel-pump-pulse {
  from { box-shadow: inset 0 0 0 1px var(--refuel-action-border-color, #ff6600); }
  to { box-shadow: inset 0 0 0 1px var(--refuel-action-active-color, #ff6600), 0 0 0.8em -0.2em var(--refuel-action-active-color, #ff6600); }
}
@media (prefers-reduced-motion: reduce) {
  .refuel-pump.pumping {
    animation: none;
  }
}

/* breadcrumb: same house pill as the computer screens (ComputerWrapper) */
.refuel-breadcrumbs {
  --bng-button-custom-margin: 0;
  flex: 0 0 auto;
  align-items: center;
  gap: 0.1em;
  padding: 0.2em 0.55em 0.2em 0.2em;
  border-radius: var(--bng-corners-2);
  background-color: rgba(var(--bng-off-black-rgb), 0.9);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 8px 24px rgba(0, 0, 0, 0.35);
  font-size: 0.95em;
  pointer-events: auto;
  :deep(.back-button) {
    --bng-bg-enabled: #fff;
    --bng-bg-enabled-opacity: 0.08;
    --bng-bg-hover: #fff;
    --bng-bg-hover-opacity: 0.16;
    --bng-bg-active: #fff;
    --bng-bg-active-opacity: 0.22;
    --bng-bg-border-enabled: transparent;
    --bng-bg-border-hover: transparent;
    --bng-bg-border-active: transparent;
    --bng-bg-border-radius: calc(var(--bng-corners-2) - 0.1em);
    --bng-button-padding: 0 0.75em 0 0.5em;
    --bng-button-padding-top: 0.32em;
    --bng-button-padding-bottom: 0.22em;
    --bng-content-align: center;
    gap: 0.3em;
    margin: 0 0.45em 0 0 !important;
    font-weight: 700;
    > .back-icon {
      width: auto;
      font-size: 1.05em;
      transform: translateY(-0.06em);
    }
  }
  :deep(.bng-path-item) {
    --bng-bg-enabled-opacity: 0;
    --bng-button-text-enabled-color: #fff;
    --bng-button-padding: 0 0.35em;
    --bng-button-padding-top: 0.32em;
    --bng-button-padding-bottom: 0.22em;
    font-weight: 700;
    .label {
      text-decoration: none;
    }
  }
}

/* status chips (top right): house black, gold money, faint slashes */
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
  overflow: hidden;
  border-radius: var(--bng-corners-2);
  color: white;
  background-color: rgba(var(--bng-off-black-rgb), 0.9);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 8px 24px rgba(0, 0, 0, 0.35);
  :deep(.card-cnt) {
    background-color: rgba(var(--bng-off-black-rgb), 0.9);
  }
  :deep(.career-status-progress .vertical-divider) {
    background: rgba(255, 255, 255, 0.28);
  }
  :deep(.career-status-progress > .career-status-value:last-child) {
    color: #fde68a;
    --units-icon-color: #fde68a;
  }
}
</style>
