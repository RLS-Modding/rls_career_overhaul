<template>
  <div class="choose-insurance-route" v-bng-scoped-nav="{ scopeId: 'root', activateOnMount: false }">
    <div
      ref="rootEl"
      class="popup-content rls-house choose-insurance"
      v-bng-blur="1"
      v-bng-scoped-nav="{ scopeId: 'choose-insurance', preferAutoFocus: true }"
      v-bng-on-ui-nav:tab_l="previousProvider" v-bng-on-ui-nav:tab_r="nextProvider"
    >
      <div class="popup-header">
        <span class="caption">
          {{ menuMode === "purchase" ? $translate.instant("ui.career.chooseInsurance.insureYour") : $translate.instant("ui.career.chooseInsurance.switchInsuranceForYour") }}
        </span>
        <h2 class="pop-title">{{ vehicleInfo?.Name }}</h2>
      </div>
      <div class="content-wrapper scroll" v-bng-ui-nav-scroll>
        <BngOverflowContainer
          v-if="hasData"
          ref="overflowRef"
          class="insurance-shelf"
          :scroll-speed="10"
          :initial-index="selectedShelfIndex"
          use-bindings-only
          show-arrows
          no-wheel
        >
          <InsuranceCard
            v-for="(insurance, index) in insurancesData"
            :key="insurance.id"
            :insuranceData="insurance"
            :isSelected="selectedInsuranceId === insurance.id"
            :vehicleInfo="vehicleInfo"
            :isCurrentProvider="menuMode === 'change' && currentInsuranceId === insurance.id"
            class="insurance-card"
            @click="onShelfClick(insurance.id, index)"
          />
        </BngOverflowContainer>
      </div>
      <div class="buttons-wrapper">
        <div class="button-container">
          <HouseButton
            variant="quiet"
            binding="back"
            :bng-scoped-nav-autofocus="selectDisabled ? '' : null"
            @click="cancel">{{ $translate.instant("ui.common.cancel") }}</HouseButton>
          <span class="button-gap"></span>
          <HouseButton @click="viewCostBreakdown" :disabled="breakdownDisabled">{{ $translate.instant("ui.career.chooseInsurance.viewCostBreakdown") }}</HouseButton>
          <HouseButton
            class="select-button"
            variant="primary"
            binding="ok"
            :disabled="selectDisabled"
            :bng-scoped-nav-autofocus="selectDisabled ? null : ''"
            @click="continueWithInsurance">{{ buttonText }}</HouseButton>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from "vue"
import { BngOverflowContainer } from "@/common/components/base"
import { vBngBlur, vBngScopedNav, vBngUiNavScroll, vBngOnUiNav } from "@/common/directives"
import useChooseInsurance from "@/modules/career/stores/chooseInsuranceComposable"
import { lua } from "@/bridge"
import InsuranceCard from "../components/insurance/insuranceCard.vue"
import PurchaseInsuranceDetails from "../components/insurance/purchaseInsuranceDetails.vue"
import ChangeInsuranceDetails from "../components/insurance/changeInsuranceDetails.vue"
import { HouseButton } from "../components/house/index.js"
import { addPopup } from "@/services/popup"
import { useUINavBlocker, useUINavTracker } from "@/services/uiNavTracker"
import { useScreenEntry } from "../composables/useScreenEntryFocus"
import { useRouteReady } from "@/services/routeReadiness"
import { $translate } from "@/services/translation"

const enterScreen = useScreenEntry()
// Track the existing shoulder actions without changing the visible action bar.
const navHints = useUINavTracker()
const hintOwner = "overhaul-choose-insurance-tabs"
onMounted(() => {
  for (const event of ["tab_l", "tab_r"]) navHints.addIgnore(event, hintOwner)
})
onUnmounted(() => {
  for (const event of ["tab_l", "tab_r"]) navHints.removeIgnore(event, hintOwner)
})
const uiNavBlocker = useUINavBlocker()
uiNavBlocker.ensureNoBlock(["tab_l", "tab_r"])

const overflowRef = ref(null)
const rootEl = ref(null)
const previousProvider = () => overflowRef.value?.activatePrev()
const nextProvider = () => overflowRef.value?.activateNext()

const props = defineProps({
  // "purchase" | "change"
  menuMode: {
    type: String,
    required: true
  },
  // purchase: { purchaseType, shopId, insuranceId? }; change: { vehicleId }
  params: {
    type: Object,
    required: true
  },
})

const selectedInsuranceId = ref(null)
const selectedShelfIndex = ref(0)

const {
  hasData,
  insurancesData,
  defaultInsuranceId,
  vehicleInfo,
  driverScoreData,
  currentInsuranceId,
} = useChooseInsurance()

onMounted(() => {

  if (props.menuMode === 'purchase' && props.params) {
    // Undefined trailing arguments produce invalid Lua calls.
    const { purchaseType, shopId, insuranceId } = props.params
    if (insuranceId === undefined || insuranceId === null) {
      lua.overhaul_career_repair_insurance.sendChooseInsuranceDataToTheUI(purchaseType, shopId)
    } else {
      lua.overhaul_career_repair_insurance.sendChooseInsuranceDataToTheUI(purchaseType, shopId, insuranceId)
    }
  } else if (props.menuMode === 'change' && props.params) {
    lua.overhaul_career_repair_insurance.sendChangeInsuranceDataToTheUI(props.params.vehicleId)
  }
})

// Sync shelf index with insurance selection
watch(selectedShelfIndex, (newIndex) => {
  if (insurancesData.value[newIndex]) {
    selectedInsuranceId.value = insurancesData.value[newIndex].id
  }
})

// set default selected insurance when data loads
watch(defaultInsuranceId, (defaultId) => {
  if (defaultId !== null && defaultId !== undefined) {
    selectedInsuranceId.value = defaultId

    const index = insurancesData.value.findIndex(ins => ins.id === defaultId)
    if (index !== -1) {
      selectedShelfIndex.value = index
    }
  }
}, { immediate: true })


const onShelfClick = (insuranceId, index) => {
  selectedInsuranceId.value = insuranceId
  selectedShelfIndex.value = index
}

const selectedInsurance = computed(() => insurancesData.value[selectedShelfIndex.value])

const selectDisabled = computed(() => !selectedInsuranceId.value || (props.menuMode === "change" && selectedInsuranceId.value === currentInsuranceId.value))

const breakdownDisabled = computed(() => {
  const insurance = selectedInsurance.value
  if (!insurance || insurance.id === -1) return true
  return props.menuMode === "change" && insurance.id === currentInsuranceId.value
})

const buttonText = computed(() => {
  if (props.menuMode === "change") {
    if (selectedInsuranceId.value === -1) {
      return $translate.instant("ui.career.chooseInsurance.removeCoverage")
    } else if (selectedInsuranceId.value === currentInsuranceId.value) {
      return $translate.instant("ui.career.chooseInsurance.currentProvider")
    } else {
      return $translate.instant("ui.career.chooseInsurance.moveVehicleHere")
    }
  }
  return $translate.instant("ui.career.chooseInsurance.selectThisOption")
})

const viewCostBreakdown = () => {
  if (breakdownDisabled.value) return
  addPopup(props.menuMode === "purchase" ? PurchaseInsuranceDetails : ChangeInsuranceDetails, {
    insuranceData: selectedInsurance.value,
    vehicleInfo: vehicleInfo.value,
    driverScoreData: driverScoreData.value,
    ...(props.menuMode === "change" ? { onSwitch: continueWithInsurance } : {}),
  })
}

// changeInvVehInsurance charges switching fees, so it must not run twice while the route is leaving
let isLeaving = false
const continueWithInsurance = () => {
  if (isLeaving || selectDisabled.value) return
  isLeaving = true
  if (props.menuMode === "purchase") {
    if (selectedInsuranceId.value !== null && selectedInsuranceId.value !== undefined) {
      lua.overhaul_career_market_vehicleShopping.updateInsuranceSelection(selectedInsuranceId.value)
    }
  } else if (props.menuMode === "change") {
    if (selectedInsuranceId.value && props.params?.vehicleId) {
      lua.overhaul_career_repair_insurance.changeInvVehInsurance(props.params.vehicleId, selectedInsuranceId.value)
    }
  }
  lua.extensions.ui_router.back()
}

const cancel = () => {
  lua.extensions.ui_router.back()
}

onUnmounted(() => {
  isLeaving = true
})

// Wait for insurance data so route autofocus finds a rendered button.
useRouteReady({
  onReady: () => enterScreen("choose-insurance"),
  async waitUntilReady() {
    if (!hasData.value) {
      await new Promise(resolve => {
        const stop = watch(hasData, ready => {
          if (!ready) return
          stop()
          resolve()
        })
      })
    }
    await nextTick()
    if (typeof window !== "undefined" && typeof window.requestAnimationFrame === "function") {
      await new Promise(resolve => window.requestAnimationFrame(() => resolve()))
    }
  },
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.choose-insurance-route {
  width: 100%;
  height: 100%;
  min-height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 2em;
}

/* RLS house popup: near-black ground, the vehicle name as the title, a shelf of equal-height
   provider cards (selected = brighter panel), footer on the same ground with no divider and one
   orange action (select / move here). */
.choose-insurance {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  display: flex;
  flex-direction: column;
  gap: var(--space-3);
  width: min(86em, 94vw);
  max-height: min(90vh, calc(100vh - 4rem));
  padding: 1.1em 1.1em 1em;
  border-radius: var(--radius-control);
  background: #1a1a1c;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08), 0 18px 40px rgba(0, 0, 0, 0.55);
  color: #fff;
  overflow: hidden;
}

.popup-header {
  flex: 0 0 auto;
  display: grid;
  gap: 0.15em;
  min-width: 0;
}
.pop-title {
  margin: 0;
  font-size: 1.45em;
  font-weight: 800;
  line-height: 1.15;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.content-wrapper {
  flex: 1 1 auto;
  min-height: 0;
  width: 100%;
  display: flex;
  flex-direction: column;
  align-items: center;
  overflow-x: hidden;
  overflow-y: auto;
  /* the stable scrollbar gutter sits in the popup's right padding */
  margin-right: -0.55em;
  padding-right: 0.05em;
}

.insurance-shelf {
  --bng-overflow-container-background: transparent;
  --bng-overflow-container-fade-color: #1a1a1c;
  --bng-overflow-container-fade-color-hover: #2a2a2d;
  --binding-font-size: 1.5em;
  --bng-overflow-container-gap: 0.6em;
  --bng-icon-color: var(--muted);

  width: 100%;
  max-width: 100%;
  font-size: 1em;
  flex: 0 0 auto;

  :deep(.shelf-container) {
    overflow: visible;
  }
  :deep(.scroll-container) {
    align-items: stretch;
    padding: 0.4em 0.25em;
  }
}

.insurance-card {
  flex: 0 0 auto;
  width: 24em;
  min-height: 32em;
  z-index: unset !important;
}

.buttons-wrapper {
  flex: 0 0 auto;
}

.button-container {
  display: flex;
  align-items: center;
  gap: var(--space-2);
  .button-gap {
    flex: 1 1 auto;
  }
  > :deep(.house-button) {
    min-width: 7em;
  }
  > .select-button {
    min-width: 12em;
  }
}
</style>
